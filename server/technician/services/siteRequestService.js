// Service requests raised BY a technician from the field (issue found at a
// site / market survey: photos + problem + location + contact). Admins review
// them and can convert one into a customer service ticket.
//
// Status: submitted -> under_review -> converted | rejected
//   (UI: Pending Review / Under Review / Converted to Ticket / Rejected)
//
// Stored in its own table so customer tickets are untouched; the table (and
// the columns added later) are created on first use if migrations have not run.
const database = require('../../database');
const { businessId } = require('../../utils/ids');
const pool = () => database.getPool();

const STATUSES = ['submitted', 'under_review', 'converted', 'rejected'];

let tableReady = null;
function ensureTable() {
  if (!tableReady) {
    tableReady = (async () => {
      await pool().query(
        `CREATE TABLE IF NOT EXISTS technician_service_requests (
          id BIGINT AUTO_INCREMENT PRIMARY KEY,
          request_no VARCHAR(30) UNIQUE NOT NULL,
          user_id BIGINT NOT NULL,
          category VARCHAR(80),
          description TEXT,
          contact_name VARCHAR(120),
          contact_number VARCHAR(20),
          address TEXT,
          latitude DECIMAL(10,7) NULL,
          longitude DECIMAL(10,7) NULL,
          photos JSON,
          status VARCHAR(40) DEFAULT 'submitted',
          ticket_no VARCHAR(40) NULL,
          converted_ticket_id BIGINT NULL,
          admin_notes TEXT NULL,
          created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
          updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
          INDEX idx_tsr_user (user_id)
        )`,
      );
      // Tables created by an earlier version lack the review columns.
      const extra = [
        ['ticket_no', 'VARCHAR(40) NULL'],
        ['converted_ticket_id', 'BIGINT NULL'],
        ['admin_notes', 'TEXT NULL'],
        ['updated_at', 'DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP'],
      ];
      for (const [name, def] of extra) {
        try {
          await pool().query(`ALTER TABLE technician_service_requests ADD COLUMN ${name} ${def}`);
        } catch (error) {
          if (error.code !== 'ER_DUP_FIELDNAME') throw error;
        }
      }
    })().catch((error) => {
      tableReady = null; // allow a retry on the next request
      throw error;
    });
  }
  return tableReady;
}

function parsePhotos(value) {
  if (Array.isArray(value)) return value;
  try {
    const parsed = JSON.parse(value || '[]');
    return Array.isArray(parsed) ? parsed : [];
  } catch (_) {
    return [];
  }
}

const num = (v) => (v === null || v === undefined ? null : Number(v));

function shape(row) {
  return {
    id: row.requestNo,
    requestNo: row.requestNo,
    category: row.category,
    description: row.description,
    address: row.address,
    contactName: row.contactName,
    contactNumber: row.contactNumber,
    latitude: num(row.latitude),
    longitude: num(row.longitude),
    photos: parsePhotos(row.photos),
    status: row.status,
    ticketNo: row.ticketNo || null,
    convertedTicketId: row.convertedTicketId === null || row.convertedTicketId === undefined ? null : Number(row.convertedTicketId),
    adminNotes: row.adminNotes || null,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  };
}

const SELECT = `SELECT id AS "databaseId",request_no AS "requestNo",category,description,address,contact_name AS "contactName",contact_number AS "contactNumber",latitude,longitude,photos,status,ticket_no AS "ticketNo",converted_ticket_id AS "convertedTicketId",admin_notes AS "adminNotes",created_at AS "createdAt",updated_at AS "updatedAt" FROM technician_service_requests`;

function countsFrom(rows) {
  const c = { submitted: 0, underReview: 0, converted: 0, rejected: 0, total: 0 };
  for (const r of rows) {
    const n = Number(r.total);
    c.total += n;
    if (r.status === 'submitted') c.submitted += n;
    else if (r.status === 'under_review') c.underReview += n;
    else if (r.status === 'converted') c.converted += n;
    else if (r.status === 'rejected') c.rejected += n;
  }
  return c;
}

// ── Technician ───────────────────────────────────────────────────────────────
async function create(user, data) {
  await ensureTable();
  const requestNo = businessId('TSR');
  const inserted = await pool().query(
    `INSERT INTO technician_service_requests
      (request_no,user_id,category,description,contact_name,contact_number,address,latitude,longitude,photos)
     VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
    [
      requestNo,
      user.id,
      data.category,
      data.description,
      data.contactName || null,
      data.contactNumber,
      data.address,
      data.latitude ?? null,
      data.longitude ?? null,
      JSON.stringify(data.photos),
    ],
  );
  return {
    id: requestNo,
    databaseId: inserted.insertId,
    status: 'submitted',
    message: 'Service request submitted successfully',
  };
}

async function list(user) {
  await ensureTable();
  const [{ rows }, counted] = await Promise.all([
    pool().query(`${SELECT} WHERE user_id=$1 ORDER BY id DESC LIMIT 200`, [user.id]),
    pool().query('SELECT status,COUNT(*) AS total FROM technician_service_requests WHERE user_id=$1 GROUP BY status', [user.id]),
  ]);
  const counts = countsFrom(counted.rows);
  return { data: rows.map(shape), total: counts.total, counts };
}

/** Counters for GET /technician/dashboard. */
async function dashboardCounts(user) {
  try {
    await ensureTable();
    const { rows } = await pool().query(
      'SELECT status,COUNT(*) AS total FROM technician_service_requests WHERE user_id=$1 GROUP BY status',
      [user.id],
    );
    const c = countsFrom(rows);
    return {
      serviceRequests: c.total,
      serviceRequestsPending: c.submitted + c.underReview,
      serviceRequestsConverted: c.converted,
    };
  } catch (_) {
    return { serviceRequests: 0, serviceRequestsPending: 0, serviceRequestsConverted: 0 };
  }
}

// ── Admin ────────────────────────────────────────────────────────────────────
async function adminList(query = {}) {
  await ensureTable();
  const where = [];
  const values = [];
  if (query.status && STATUSES.includes(query.status)) {
    values.push(query.status);
    where.push(`status=$${values.length}`);
  }
  const { rows } = await pool().query(
    `SELECT r.id AS "databaseId",r.request_no AS "requestNo",r.category,r.description,r.address,r.contact_name AS "contactName",r.contact_number AS "contactNumber",r.latitude,r.longitude,r.photos,r.status,r.ticket_no AS "ticketNo",r.converted_ticket_id AS "convertedTicketId",r.admin_notes AS "adminNotes",r.created_at AS "createdAt",r.updated_at AS "updatedAt",u.name AS "technicianName",u.mobile AS "technicianMobile"
     FROM technician_service_requests r JOIN users u ON u.id=r.user_id
     ${where.length ? 'WHERE ' + where.join(' AND ').replace(/status/g, 'r.status') : ''} ORDER BY r.id DESC LIMIT 500`,
    values,
  );
  return {
    data: rows.map((r) => ({ ...shape(r), databaseId: r.databaseId, technicianName: r.technicianName, technicianMobile: r.technicianMobile })),
    total: rows.length,
  };
}

async function findByNo(requestNo) {
  const { rows } = await pool().query(`${SELECT} WHERE request_no=$1`, [requestNo]);
  if (!rows[0]) throw Object.assign(new Error('Service request not found'), { status: 404 });
  return rows[0];
}

async function notifyTechnician(requestNo, title, body) {
  try {
    const { rows } = await pool().query('SELECT user_id FROM technician_service_requests WHERE request_no=$1', [requestNo]);
    if (rows[0]) {
      await require('../../services/notificationService').sendEvent(rows[0].user_id, 'service.request_update', title, body, { requestNo });
    }
  } catch (_) {
    /* best-effort */
  }
}

/** Admin: set under_review / rejected / submitted and add admin notes. */
async function adminUpdate(requestNo, data) {
  await ensureTable();
  const current = await findByNo(requestNo);
  if (current.status === 'converted')
    throw Object.assign(new Error('This request is already converted to a ticket'), { status: 409 });
  await pool().query(
    'UPDATE technician_service_requests SET status=COALESCE($2,status),admin_notes=COALESCE($3,admin_notes) WHERE request_no=$1',
    [requestNo, data.status || null, data.adminNotes ?? null],
  );
  if (data.status && data.status !== current.status) {
    await notifyTechnician(requestNo, 'Service request update', `Your request ${requestNo} is now: ${data.status.replace('_', ' ')}.`);
  }
  return shape(await findByNo(requestNo));
}

/** Admin: convert into a customer service ticket (needs the customer it is for). */
async function adminConvert(requestNo, data) {
  await ensureTable();
  const request = await findByNo(requestNo);
  if (request.status === 'converted')
    throw Object.assign(new Error('This request is already converted to a ticket'), { status: 409 });
  const customer = (await pool().query('SELECT id FROM customers WHERE id=$1', [data.customerId])).rows[0];
  if (!customer) throw Object.assign(new Error('Customer not found'), { status: 404 });
  const ticketNo = businessId('SB-SRV');
  const location = {
    address: request.address,
    latitude: num(request.latitude),
    longitude: num(request.longitude),
    contactName: request.contactName || null,
    contactNumber: request.contactNumber,
    source: 'technician_field_request',
    requestNo,
  };
  const inserted = await pool().query(
    `INSERT INTO service_tickets(ticket_no,customer_id,category,description,location,photos,priority,status)
     VALUES($1,$2,$3,$4,$5,$6,$7,'submitted')`,
    [ticketNo, customer.id, request.category, request.description, JSON.stringify(location), JSON.stringify(parsePhotos(request.photos)), data.priority || 'normal'],
  );
  await pool().query(
    "UPDATE technician_service_requests SET status='converted',ticket_no=$2,converted_ticket_id=$3,admin_notes=COALESCE($4,admin_notes) WHERE request_no=$1",
    [requestNo, ticketNo, inserted.insertId, data.adminNotes ?? null],
  );
  await notifyTechnician(requestNo, 'Service request converted', `Your request ${requestNo} was converted to ticket ${ticketNo}.`);
  return shape(await findByNo(requestNo));
}

module.exports = { STATUSES, create, list, dashboardCounts, adminList, adminUpdate, adminConvert };
