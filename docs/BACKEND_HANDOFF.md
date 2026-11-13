# SignFix – Backend Handoff

For: backend engineer · Branch: `feature/payments-ai-preview-technician-requests` (GitHub: alizasaeed02/signfix)

The Flutter apps (customer + technician) and the admin web page are finished. Most of the server code is already written in `server/` on the branch above; this document lists what to **deploy**, what the apps **expect from the API**, and what still needs a **backend decision**. Nothing here has been run against the live database – please test the checklist at the end.

---

## 1. Deploy checklist

1. Pull the branch and deploy the whole `server/` folder, plus the admin web app (`src/`).
2. Restart the API.
3. Database: **one new table**, `technician_service_requests` (SQL at the end of `database/schema.mysql.sql`). The code also creates it automatically on first use if the DB user has `CREATE` permission – running the SQL once yourself is safer. **No other migration is needed.**
4. Razorpay dashboard: UPI (GPay/PhonePe/Paytm + QR), cards, net banking and wallets enabled; confirm per-transaction limits cover order amounts (e.g. ₹41,654).

Server files changed or added:

| File | Change |
|---|---|
| `server/controllers/authController.js` | Pending technician sign-up via Google/phone; `accountStatus` in sign-in responses |
| `server/technician/middleware/requireApprovedTechnician.js` | **New** – blocks live job actions until approved |
| `server/technician/routes/technicianRoutes.js` | Guard applied; new service-request routes |
| `server/technician/repositories/technicianRepository.js` | Profile returns `accountStatus`, `workLocation`; saves `workLocation` |
| `server/technician/validation/technicianSchemas.js` | Profile accepts `workLocation` |
| `server/technician/controllers/technicianController.js`, `services/siteRequestService.js` (**new**) | Technician-raised service requests |
| `server/admin/controllers/operationsController.js`, `routes/operationsRoutes.js` | `POST /technicians/:id/approve`; `accountStatus` in list/detail |
| `src/pages/admin/TechniciansPage.jsx` | Pending badge, **Approve** button, profile details |
| `server/customer/routes/customerRoutes.js`, `repositories/customerRepository.js`, `server/services/razorpayService.js` | AI preview route and payment changes (already in the branch) |

---

## 2. Technician approval workflow

**State** – no new DB column or status value. `users.status` has a CHECK limited to `active | disabled | pending_verification | deleted`, so the existing meaning is reused:

- `pending_verification` **and** `verified_at` set  →  technician **pending approval**
- `active`  →  approved

**Sign-up / sign-in (technician portal)**

- `POST /api/auth/google` with `portal: "technician"` and `POST /api/auth/firebase-phone` with `role: "technician"`: an unknown user is now **created** as a technician (`status='pending_verification'`, `verified_at=NOW()`, empty `technicians` row) instead of returning `NOT_A_TECHNICIAN`. An existing *customer* email/phone still gets `NOT_A_TECHNICIAN`.
- Email/password login, Google and phone login now **allow** pending technicians (previously 403 "pending admin approval").
- Sign-in responses: `user.accountStatus` = `"pending_approval"` | `"active"`.

**Read-only for pending technicians**

`requireApprovedTechnician` (checks `users.status` in the DB on every request, so approval is instant) is applied to:
`GET /technician/jobs/:id/navigation`, `PATCH …/status`, `POST …/evidence`, `…/materials`, `…/location`, `…/completion-otp`, `…/confirm`.

It returns **403** `{ "error": "You can accept jobs only after admin approval.", "code": "TECHNICIAN_NOT_APPROVED" }`. The app keys on that `code`. Listing/reading endpoints (dashboard, jobs list, profile, notifications) stay open.

**Profile (technician completes own details – "Option A")**

- `GET /api/technician/profile` now also returns `accountStatus` and `workLocation` (first entry of `service_areas`).
- `PATCH /api/technician/profile` accepts `workLocation` (string → stored as `service_areas = ["<city>"]`), `skills` (string[]), `mobile`.

**Admin ("Option B" and approval)**

- Existing `PATCH /api/admin/operations/technicians/:id` already edits name, mobile, `serviceAreas` (work location/city), `skills`.
- **New** `POST /api/admin/operations/technicians/:id/approve` → sets `users.status='active'`, writes an audit log, sends the technician an in-app notification (event `technician.approved`, best-effort). Returns 409 if the account is `disabled`.
- List/detail responses include `accountStatus` (`pending_approval` | `active` | `disabled`).

The technician app re-checks `GET /technician/profile` on open, every 30 s while pending, and on resume, so approval unlocks it without re-login.

---

## 3. Technician service requests (field-raised)

New page in the technician app: photos, category, description, **contact number**, site address, GPS. Same fields as the customer request.

- `POST /api/technician/service-requests` – body: `category`, `description` (≥10 chars), `address`, `contactNumber`, `photos` (1–10 URLs from `POST /api/uploads`), optional `contactName`, `latitude`, `longitude`. → `201 { id, status, message }` (id like `TSR-2026-000123`).
- `GET /api/technician/service-requests` → `{ data: [...] }` (the technician's own).
- Stored in `technician_service_requests` (separate from customer tickets, which require a `customer_id`).

**Not built – needs a decision:** nothing in the admin panel lists these requests yet, and there is no conversion to a ticket/job.

---

## 4. AI preview (customer apps)

Endpoint per your guide: `POST /api/customer/designs/preview`. The app now sends exactly:

```json
{ "businessName": "...", "color": "Gold", "material": "Glossy Black Acrylic",
  "width": 10.0, "height": 3.0, "unit": "ft" }
```

- `material` is always one of the 5 supported backing materials (the app maps other values, e.g. "Aluminium" → "Silver Aluminium Panel").
- `color` is a colour **name** (a picked colour is mapped to the nearest name, e.g. Gold, White, Navy, Deep Blue, Soft Gray, Black, Red…).
- Response read: `imageUrl` (also accepted nested under `data`). Timeout: 120 s.
- Fallback: if the route returns 404 the app falls back to `POST /customer/ai/chat` and extracts an image URL from the reply.
- The same card is used on the Order wizard, Design Studio and Power Supply. **Power Supply has no sign size**, so it sends the length from its wattage calculator as `width` and `height: 1.0` – tell us if a better value should be used.

---

## 5. Payments & orders – what the customer app expects

**Orders list (`GET /api/customer/orders`)** – for each order:

- `status` – exactly one of: `payment_pending`, `under_review`, `quotation`, `approved`, `production`, `ready`, `installation`, `completed`, `cancelled` (the app also accepts `in_production` as `production`; any other value is shown as-is).
- **`paymentFailed: true`** when the last payment failed → the app shows **Retry Payment** on that order.
- **`paymentId`** – id of that failed payment (the app also reads `failedPaymentId`, `lastPaymentId` or `payment.id`). Needed for the retry call; without it the app falls back to creating a new payment intent.
- Optional `paymentType` (`full` | `advance`) so the retry shows the right amount.

**Endpoints used (per payment guide)**

- `POST /api/customer/payments/order-intents` `{ orderNo, type, idempotencyKey }` → `{ id, checkout{ keyId, orderId, amount(paise), currency, name, description } }`
- `POST /api/customer/payments/:id/verify`, `…/failure`, `…/retry` (retry returns the same shape as an intent).
- The app auto-retries network failures on these calls (same idempotency key), so they must stay idempotent.

**Known server behaviour the app works around:** only one open payment per order. If an earlier attempt is still open under the *other* type, the intent call returns **409** with a message containing "in progress"; the app then continues that payment. Please keep that message wording, or tell us a stable error code to use instead.

---

## 6. Open questions / decisions for you

1. **Phone number format:** `firebasePhoneAuth` only accepts 10-digit Pakistani numbers (`92…`, regex `^[3]\d{9}$`), but the technician registration form in the app uses **+91** numbers. Which is correct? Phone sign-in will fail for numbers that do not match.
2. **Admin listing/conversion** for technician service requests (section 3).
3. **Older email registration flow** (3-step form + OTP) still exists and ends on a "pending approval" screen; it now also lets pending technicians sign in. Keep it or remove it?
4. Power Supply AI preview size values (section 4).
5. Orders API fields in section 5 (`paymentFailed`, `paymentId`, status values) – the app is ready; the live API must return them.

---

## 7. Test checklist

**Technician approval**
- [ ] Google sign-in (technician portal) with a new email → account created, app opens, banner shown, `accountStatus = pending_approval`.
- [ ] Same for a new phone number (OTP).
- [ ] As the pending technician: `PATCH /technician/jobs/:id/status` → 403 `TECHNICIAN_NOT_APPROVED`; `GET /technician/jobs` and `/profile` → 200.
- [ ] `PATCH /technician/profile` with `workLocation`, `skills`, `mobile` → saved; admin sees them.
- [ ] Admin: technician list shows "pending_approval" + **Approve**; after approving, the technician app drops the banner within ~30 s and job actions succeed (no re-login).
- [ ] Admin edit of a pending technician does **not** activate them.

**Service requests:** submit with photos → row in `technician_service_requests`; `GET` returns it.

**AI preview:** from each of the 3 flows → image returned; invalid input returns a readable 422.

**Payments:** UPI with a typed UPI ID sends a collect request to that ID; QR opens QR; failed payment → order shows `paymentFailed` + Retry Payment → `/retry` returns a working session; Full-then-Advance on the same order does not dead-end.
