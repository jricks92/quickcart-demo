// QuickCart — a tiny demo store.

const PRODUCTS = [
  { id: "widget", name: "Widget", price: 19.99 },
  { id: "gadget", name: "Gadget", price: 49.99 },
  { id: "gizmo", name: "Gizmo", price: 9.99 },
];

// Cart starts with a few items so the total is visible on load.
const cart = [
  { id: "widget", quantity: 2 },
  { id: "gadget", quantity: 1 },
  { id: "gizmo", quantity: 3 },
];

function productById(id) {
  return PRODUCTS.find((p) => p.id === id);
}

// Compute the cart total in dollars.
function cartTotal() {
  return cart.reduce((sum, item) => {
    const product = productById(item.id);
    return sum + (product.price * item.quantity);
  }, 0);
}

function formatMoney(amount) {
  return "$" + amount.toFixed(2);
}

function renderProducts() {
  const list = document.getElementById("product-list");
  list.innerHTML = "";
  for (const p of PRODUCTS) {
    const li = document.createElement("li");
    li.className = "product";
    li.innerHTML =
      '<span><span class="product-name">' +
      p.name +
      '</span><span class="product-price">' +
      formatMoney(p.price) +
      "</span></span>" +
      '<button class="add-btn" data-id="' +
      p.id +
      '">Add</button>';
    list.appendChild(li);
  }
}

function renderCart() {
  const list = document.getElementById("cart-list");
  list.innerHTML = "";
  for (const item of cart) {
    const p = productById(item.id);
    const li = document.createElement("li");
    li.className = "cart-item";
    li.innerHTML =
      "<span>" +
      p.name +
      ' <span class="qty">x' +
      item.quantity +
      "</span></span>" +
      "<span>" +
      formatMoney(p.price * item.quantity) +
      "</span>";
    list.appendChild(li);
  }
  document.getElementById("cart-total").textContent = formatMoney(cartTotal());
}

function addToCart(id) {
  const existing = cart.find((item) => item.id === id);
  if (existing) {
    existing.quantity += 1;
  } else {
    cart.push({ id, quantity: 1 });
  }
  renderCart();
}

document.addEventListener("click", (e) => {
  if (e.target.classList.contains("add-btn")) {
    addToCart(e.target.getAttribute("data-id"));
  }
});

renderProducts();
renderCart();
