"""Code-execution MCP broker.

Exposes ONE tool, run_python, that:
  1. builds a scoped, parameterized DynamoDB Query from the LLM's params,
  2. fetches the bounded orders slice (this pod holds read-only creds),
  3. vends a fresh air-gapped kata-fc microVM and injects the rows + code as
     files (out-of-band — the data never passes through the LLM),
  4. runs the untrusted code in the microVM and returns capped stdout.

If the code drew a chart to /app/chart.png, the broker caches those PNG bytes
and returns only a short `chart_id` to the agent — the image is served
out-of-band via GET /chart/{id} (a custom route that skips MCP auth). So the
chart, like the order rows, never passes through the LLM.

The microVM has no network and no credentials; all trust lives in this broker.
"""

import json
import os

import boto3
from boto3.dynamodb.types import TypeDeserializer
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from starlette.requests import Request
from starlette.responses import Response

from chart_cache import ChartCache
from query import build_query_kwargs, InvalidQueryParam
from sandbox_runner import run_in_sandbox

# DNS-rebinding protection blocks in-cluster DNS; this is a ClusterIP behind
# agentgateway, not a browser-facing localhost server (same as the 500 server).
mcp = FastMCP(
    "AnyCompany Code Executor",
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
)

_REGION = os.environ.get("AWS_REGION")
_TABLE = os.environ["ORDERS_TABLE"]
_client = boto3.client("dynamodb", region_name=_REGION)
_deser = TypeDeserializer()

# Holds chart PNGs between the tool returning and the agent fetching them.
_charts = ChartCache()


def _fetch_rows(**params) -> list[dict]:
    """Run the scoped Query and return plain (deserialized) order dicts."""
    kwargs = build_query_kwargs(_TABLE, **params)
    rows: list[dict] = []
    while True:
        resp = _client.query(**kwargs)
        for item in resp.get("Items", []):
            row = {k: _deser.deserialize(v) for k, v in item.items()}
            # `items` is stored as a JSON string ({"S": json.dumps(...)}), so it
            # deserializes to a str. Parse it back to a list so the sandbox sees
            # the shape the run_python docstring promises (list of {name,qty,price}).
            # Mirrors lookup_order in the 500 mcp-server.
            if isinstance(row.get("items"), str):
                row["items"] = json.loads(row["items"])
            # `total` is likewise stored as a String; hand the sandbox a float so
            # pandas sums it instead of concatenating strings.
            if isinstance(row.get("total"), str):
                row["total"] = float(row["total"])
            rows.append(row)
        lek = resp.get("LastEvaluatedKey")
        if not lek:
            break
        kwargs["ExclusiveStartKey"] = lek
    return rows


@mcp.tool()
def run_python(
    code: str,
    period: str,
    region: str | None = None,
    status: str | None = None,
    payment_method: str | None = None,
    channel: str | None = None,
) -> dict:
    """Run Python against a scoped slice of the orders dataset in an isolated microVM.

    Use this for any analytical/computational question over multiple orders
    (aggregations, trends, breakdowns) — write Python instead of asking for raw
    rows. The code runs hardware-isolated (Firecracker microVM), air-gapped, with
    no network and no credentials.

    Your `code` runs in /app. The queried rows are available as /app/orders.json
    — a JSON list of order dicts, each with these keys:
      order_id (str), customer (str), status (str: shipped|delivered|processing|
      cancelled|returned), tracking (str, ABSENT for processing/cancelled),
      estimated_delivery (str ISO date), shipping_address (str),
      items (list of {name, qty, price}), total (float — the order's full
      value, sum of qty*price over items), order_date (str ISO date),
      period (str e.g. "2026-Q1"), region (West|South|Central|East),
      state (2-letter), payment_method (credit_card|debit_card|gift_card),
      channel (web|mobile).
    For sales/revenue aggregations use the `total` field directly, e.g.
    df.groupby('state')['total'].sum(). There are NO other numeric columns at
    the top level; per-product analysis requires exploding `items`.
    pandas is preinstalled. print() your result — only stdout is returned.

    CHARTS: to show the user a chart (e.g. "plot last month's sales by day"),
    use matplotlib (preinstalled, headless Agg backend) and save EXACTLY ONE
    figure to /app/chart.png, e.g.:
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(figsize=(7, 4))
        series.plot(kind="bar", ax=ax); ax.set_title("...")
        fig.tight_layout(); fig.savefig("/app/chart.png", dpi=100)
    The PNG is shown inline to the user automatically — do NOT print base64 or a
    file path. Keep it small (figsize ~ (7,4), dpi ~100). Still print() a short
    text summary of the numbers; the chart complements the answer, not replaces it.

    TIME RANGE: data is fetched a whole fiscal quarter at a time. For "last
    month" (or any single month), pass the quarter that contains it as `period`,
    then filter/group in your code by parsing `order_date` — e.g.
    df['order_date'] = pd.to_datetime(df['order_date']); pick the latest month
    present with df['order_date'].dt.to_period('M').max(). "Last month" = the
    most recent month that appears in the fetched quarter's data.

    Args:
      code: the Python source to run (reads /app/orders.json, prints the result,
        optionally saves a chart to /app/chart.png).
      period: REQUIRED fiscal quarter to fetch, e.g. "2026-Q1".
      region: optional filter (West|South|Central|East).
      status: optional filter (shipped|delivered|processing|cancelled|returned).
      payment_method: optional filter (credit_card|debit_card|gift_card).
      channel: optional filter (web|mobile).
    """
    try:
        rows = _fetch_rows(
            period=period, region=region, status=status,
            payment_method=payment_method, channel=channel,
        )
    except InvalidQueryParam as e:
        return {"error": f"invalid query parameter: {e}"}

    result = run_in_sandbox(code, rows)
    result["row_count"] = len(rows)

    # Swap raw PNG bytes for an opaque chart_id: the agent gets the id (tiny),
    # the bytes stay in the broker and are fetched out-of-band via /chart/{id}.
    # This keeps the image off the LLM path, exactly like the order rows.
    image_png = result.pop("image_png", None)
    if image_png:
        result["chart_id"] = _charts.put(image_png)
    return result


@mcp.custom_route("/chart/{chart_id}", methods=["GET"])
async def get_chart(request: Request) -> Response:
    """Serve a cached chart PNG by id (out-of-band; never through the LLM).

    Auth-free by design: custom_route bypasses MCP authorization, and the id is
    an unguessable short-lived token for a non-sensitive aggregate chart. The
    agent calls this in-cluster after run_python hands it a chart_id.
    """
    png = _charts.get(request.path_params["chart_id"])
    if png is None:
        return Response("chart not found or expired", status_code=404)
    return Response(
        png,
        media_type="image/png",
        headers={"Cache-Control": "no-store"},
    )


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(mcp.streamable_http_app(), host="0.0.0.0", port=8080)
