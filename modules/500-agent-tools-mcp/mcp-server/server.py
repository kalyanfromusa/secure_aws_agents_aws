import boto3, json, os

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

# DNS rebinding protection blocks in-cluster DNS like `mcp-server.default.svc.
# cluster.local`. That protection matters for browsers hitting localhost; this
# is a ClusterIP Service only other pods talk to, so we turn it off.
mcp = FastMCP(
    "AnyCompany Tools",
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
)

_TABLE = boto3.resource("dynamodb", region_name=os.environ.get("AWS_REGION")).Table(os.environ["ORDERS_TABLE"])

INVENTORY = {
    "Laptop Pro 15": 23, "Wireless Mouse": 156, "USB-C Hub": 89,
    "Noise Cancelling Headphones": 45, "Mechanical Keyboard": 67,
    "4K Monitor 27-inch": 12, "Webcam HD Pro": 98,
    "Portable Charger 20000mAh": 203, "Wireless Earbuds": 134, "Laptop Stand": 76,
}


@mcp.tool()
def lookup_order(order_id: str) -> dict:
    """Look up order status, tracking, and details by order ID."""
    resp = _TABLE.get_item(Key={"order_id": order_id.upper()})
    item = resp.get("Item")
    if not item:
        return {"error": f"Order {order_id} not found."}
    items = json.loads(item["items"])
    order = {
        "customer": item["customer"],
        "items": items,
        "status": item["status"],
        "tracking": item.get("tracking"),
        "estimated_delivery": item["estimated_delivery"],
    }
    total = float(sum(i["price"] * i["qty"] for i in items))
    return {"order_id": order_id.upper(), **order, "total": f"${total:.2f}"}


@mcp.tool()
def check_inventory(product_name: str) -> dict:
    """Check stock availability for a product."""
    for name, qty in INVENTORY.items():
        if product_name.lower() in name.lower():
            return {"product": name, "in_stock": qty > 0, "quantity": qty}
    return {"error": f"Product '{product_name}' not found in inventory."}


@mcp.tool()
def initiate_return(order_id: str, reason: str) -> dict:
    """Initiate a return for an order. Returns a return authorization number."""
    resp = _TABLE.get_item(Key={"order_id": order_id.upper()})
    item = resp.get("Item")
    if not item:
        return {"error": f"Order {order_id} not found."}
    if item["status"] == "processing":
        return {"error": "Cannot return an order that hasn't shipped yet. Please cancel instead."}
    return {
        "return_id": f"RET-{order_id.upper().replace('ORD-', '')}",
        "order_id": order_id.upper(),
        "status": "approved",
        "reason": reason,
        "instructions": "Ship the item to: AnyCompany Returns, 100 Warehouse Blvd, Seattle, WA 98101",
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(mcp.streamable_http_app(), host="0.0.0.0", port=8080)
