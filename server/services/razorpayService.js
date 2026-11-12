const crypto = require("crypto");

function configured() {
  return (
    process.env.PAYMENT_GATEWAY_ENABLED === "true" &&
    (process.env.PAYMENT_GATEWAY_PROVIDER || "").toLowerCase() === "razorpay" &&
    Boolean(process.env.RAZORPAY_KEY_ID && process.env.RAZORPAY_KEY_SECRET)
  );
}

function assertConfigured() {
  if (!configured())
    throw Object.assign(new Error("Razorpay is not configured"), {
      status: 503,
    });
}

async function requestOnce(path, options = {}) {
  assertConfigured();
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15000);
  try {
    const response = await fetch(`https://api.razorpay.com/v1${path}`, {
      ...options,
      signal: controller.signal,
      headers: {
        Authorization: `Basic ${Buffer.from(`${process.env.RAZORPAY_KEY_ID}:${process.env.RAZORPAY_KEY_SECRET}`).toString("base64")}`,
        "Content-Type": "application/json",
        Accept: "application/json",
        "User-Agent": "SignFix-Node/1.0",
        ...options.headers,
      },
    });
    const text = await response.text().catch(() => "");
    let body = {};
    try {
      body = text ? JSON.parse(text) : {};
    } catch (_) {
      body = {};
    }
    if (!response.ok) {
      console.error(
        `[razorpay] ${options.method || "GET"} ${path} -> ${response.status}: ${text.slice(0, 500)}`,
      );
      throw Object.assign(
        new Error(
          body?.error?.description ||
            `Payment provider request failed (HTTP ${response.status})`,
        ),
        {
          status: 502,
          providerCode: body?.error?.code,
          providerHttpStatus: response.status,
        },
      );
    }
    return body;
  } catch (error) {
    if (error.name === "AbortError")
      throw Object.assign(new Error("Payment provider timed out"), {
        status: 504,
        providerCode: "NETWORK_TIMEOUT",
        providerHttpStatus: 504,
      });
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

// Transient gateway failures (5xx, timeouts, network drops) are retried once.
// Order creation is safe to repeat: an unused Razorpay order is harmless.
async function request(path, options = {}) {
  try {
    return await requestOnce(path, options);
  } catch (error) {
    const transient =
      error.providerHttpStatus >= 500 ||
      error.providerCode === "NETWORK_TIMEOUT" ||
      (error.providerHttpStatus === undefined && error.status !== 503);
    if (!transient || path !== "/orders") throw error;
    await new Promise((resolve) => setTimeout(resolve, 600));
    return requestOnce(path, options);
  }
}

const createOrder = ({ amount, currency, receipt, notes }) =>
  request("/orders", {
    method: "POST",
    body: JSON.stringify({
      amount: Math.round(Number(amount) * 100),
      currency,
      receipt,
      notes,
    }),
  });
const fetchPayment = (id) => request(`/payments/${encodeURIComponent(id)}`);
const createRefund = (paymentId, { amount, notes }) =>
  request(`/payments/${encodeURIComponent(paymentId)}/refunds`, {
    method: "POST",
    body: JSON.stringify({ amount, notes, speed: "normal" }),
  });

// Accounts without automatic capture leave payments "authorized"; Razorpay
// refunds those after a few days, so they are captured here explicitly.
const autoCaptureEnabled = () => process.env.RAZORPAY_AUTO_CAPTURE !== "false";
async function capturePayment(id, amountInPaise, currency) {
  try {
    return await request(`/payments/${encodeURIComponent(id)}/capture`, {
      method: "POST",
      body: JSON.stringify({ amount: amountInPaise, currency }),
    });
  } catch (error) {
    // A concurrent webhook or dashboard auto-capture may have won the race.
    const current = await fetchPayment(id);
    if (current.status === "captured") return current;
    throw error;
  }
}

function safeEqual(given, expected) {
  const left = Buffer.from(given || "", "utf8"),
    right = Buffer.from(expected || "", "utf8");
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

function verifyCheckoutSignature(
  providerOrderId,
  providerPaymentId,
  signature,
) {
  assertConfigured();
  const expected = crypto
    .createHmac("sha256", process.env.RAZORPAY_KEY_SECRET)
    .update(`${providerOrderId}|${providerPaymentId}`)
    .digest("hex");
  return safeEqual(signature, expected);
}

function verifyWebhook(rawBody, signature) {
  const secret = process.env.RAZORPAY_WEBHOOK_SECRET;
  if (!secret)
    throw Object.assign(new Error("Razorpay webhook is not configured"), {
      status: 503,
    });
  const expected = crypto
    .createHmac("sha256", secret)
    .update(rawBody)
    .digest("hex");
  return safeEqual(signature, expected);
}

module.exports = {
  configured,
  createOrder,
  fetchPayment,
  createRefund,
  capturePayment,
  autoCaptureEnabled,
  verifyCheckoutSignature,
  verifyWebhook,
};
