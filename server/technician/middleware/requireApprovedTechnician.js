// Live job actions (accept / start / complete / evidence / navigation) are only
// for technicians an admin has activated. Pending technicians can sign in and
// explore the app read-only. Checked against the database on every request so
// approval takes effect immediately, without a new sign-in.
const database = require('../../database');

module.exports = async function requireApprovedTechnician(req, res, next) {
  try {
    const { rows } = await database
      .getPool()
      .query('SELECT status FROM users WHERE id=$1', [req.user.id]);
    if (rows[0] && rows[0].status === 'active') return next();
    return res.status(403).json({
      error: 'You can accept jobs only after admin approval.',
      code: 'TECHNICIAN_NOT_APPROVED',
    });
  } catch (error) {
    next(error);
  }
};
