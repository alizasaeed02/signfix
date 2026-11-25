# App Store review - backend notes

## 1. Sign in with Apple endpoint (Guideline 4.8)
`POST /api/auth/apple`  body: `{ "idToken": "<Apple identity token>", "portal": "customer|technician", "name": "optional" }`
- Verifies the token against https://appleid.apple.com/auth/keys (RS256), issuer `https://appleid.apple.com`,
  audience = iOS bundle id `com.signfix.app` (override with env `APPLE_AUDIENCES`, comma separated).
- Finds/creates the user by the token's e-mail (may be a `@privaterelay.appleid.com` address) exactly like
  `/auth/google`, and returns `{ token, user }`. Code: `server/controllers/authController.js` (`appleAuth`,
  shared `completeSocialLogin`), route in `server/routes/authRoutes.js`.
- The live server must expose `/auth/apple` with the same behaviour.

## 2. Demo accounts for App Review (Guideline 2.1)
Run on the server (values are not stored in the repo):
`DEMO_CUSTOMER_EMAIL=... DEMO_TECHNICIAN_EMAIL=... DEMO_PASSWORD='...' npm run demo:accounts`
- Both accounts are `active` and verified: e-mail + password login only, no OTP, no admin approval.
- One login cannot be both roles (a user has a single role), so the review gets two logins with the same password.
