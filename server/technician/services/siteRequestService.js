// Service requests raised BY a technician from the field (issue found at a
// site: photos + problem + location + contact number). Mirrors the customer
// service-request form. Stored in its own table so customer tickets are
// untouched; the table is created on first use if the migration has not run.
const database = require('../../database');
const { businessId } = require('../../utils/ids');
const pool = () => database.getPool();

let tableReady = null;
function ensureTable() {
  if (!tableReady) {
    tableReady = pool()
      .query(
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
          created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
          INDEX idx_tsr_user (user_id)
        )`,
      )
      .catch((error) => {
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

async function create(user, data) {
  await ensureTable();
  const requestNo = businessId('TSR');
  await pool().query(
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
    status: 'submitted',
    message: 'Your service request has been submitted to the SignFix team.',
  };
}

async function list(user) {
  await ensureTable();
  const { rows } = await pool().query(
    `SELECT request_no AS id,category,description,contact_name AS "contactName",contact_number AS "contactNumber",address,latitude,longitude,photos,status,created_at AS "createdAt"
     FROM technician_service_requests WHERE user_id=$1 ORDER BY id DESC LIMIT 100`,
    [user.id],
  );
  return rows.map((row) => ({ ...row, photos: parsePhotos(row.photos) }));
}

module.exports = { create, list };
