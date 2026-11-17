// Creates (or resets) the App Store / Play review demo accounts:
//   a CUSTOMER and a TECHNICIAN, both active and verified - no OTP and no admin
//   approval is needed. They sign in with e-mail + password only.
//
// Usage (on the server, from the project root):
//   DEMO_CUSTOMER_EMAIL=a@x.com DEMO_TECHNICIAN_EMAIL=b@x.com DEMO_PASSWORD='...' npm run demo:accounts
// All three values are required and are never stored in the repository.
//
// Safe to run again: it resets the password / status of the same two e-mails.
require('./config');
const bcrypt = require('bcryptjs');
const database = require('./database');

const customerEmail = String(process.env.DEMO_CUSTOMER_EMAIL || '').trim().toLowerCase();
const technicianEmail = String(process.env.DEMO_TECHNICIAN_EMAIL || '').trim().toLowerCase();
const password = process.env.DEMO_PASSWORD || '';

async function upsertUser(pool, roleName, email, name, mobile, hash) {
  const role = (await pool.query('SELECT id FROM roles WHERE name=$1 LIMIT 1', [roleName])).rows[0];
  if (!role) throw new Error(`Role "${roleName}" is missing; run npm run db:seed first`);
  const existing = (await pool.query('SELECT id,role_id FROM users WHERE email=$1 LIMIT 1', [email])).rows[0];
  if (existing) {
    if (Number(existing.role_id) !== Number(role.id)) {
      throw new Error(`${email} already exists with a different role. Use another e-mail via DEMO_${roleName.toUpperCase()}_EMAIL.`);
    }
    await pool.query(
      "UPDATE users SET name=$2,password_hash=$3,status='active',verified_at=COALESCE(verified_at,NOW()) WHERE id=$1",
      [existing.id, name, hash],
    );
    return { id: existing.id, created: false };
  }
  const result = await pool.query(
    "INSERT INTO users(role_id,name,email,mobile,password_hash,status,verified_at) VALUES($1,$2,$3,$4,$5,'active',NOW())",
    [role.id, name, email, mobile, hash],
  );
  return { id: result.insertId, created: true };
}

(async () => {
  if (!database.isConfigured()) throw new Error('DATABASE_URL is not set');
  if (!customerEmail || !technicianEmail || password.length < 6) {
    throw new Error('Set DEMO_CUSTOMER_EMAIL, DEMO_TECHNICIAN_EMAIL and DEMO_PASSWORD (6+ chars)');
  }
  const pool = database.getPool();
  const hash = await bcrypt.hash(password, 12);

  const customer = await upsertUser(pool, 'customer', customerEmail, 'Demo Customer', '9000000001', hash);
  const hasCustomerRow = (await pool.query('SELECT id FROM customers WHERE user_id=$1', [customer.id])).rows[0];
  if (!hasCustomerRow) {
    await pool.query('INSERT INTO customers(user_id,company_name,address) VALUES($1,$2,$3)', [
      customer.id,
      'Demo Customer',
      JSON.stringify({ city: 'Delhi', state: 'Delhi' }),
    ]);
  }

  const technician = await upsertUser(pool, 'technician', technicianEmail, 'Demo Technician', '9000000002', hash);
  const hasTechRow = (await pool.query('SELECT id FROM technicians WHERE user_id=$1', [technician.id])).rows[0];
  if (!hasTechRow) {
    await pool.query(
      'INSERT INTO technicians(user_id,service_areas,skills,location_sharing,terms_accepted_at) VALUES($1,$2,$3,TRUE,NOW())',
      [technician.id, JSON.stringify(['Delhi']), JSON.stringify(['LED Signage', 'Installation'])],
    );
  }

  console.log('Demo accounts ready (no OTP, no approval needed):');
  console.table([
    { portal: 'Customer', email: customerEmail, created: customer.created },
    { portal: 'Technician', email: technicianEmail, created: technician.created },
  ]);
  await pool.end();
})().catch((error) => {
  console.error('Demo account setup failed:', error.message);
  process.exit(1);
});
