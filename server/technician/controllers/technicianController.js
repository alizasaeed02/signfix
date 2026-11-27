const repo=require('../repositories/technicianRepository'); // technician-owned data access
const service=require('../services/technicianService');

async function dashboard(req,res){res.json({data:await repo.dashboardStats(req.user)});}
async function profile(req,res){const data=await repo.getProfile(req.user.id);if(!data)return res.status(404).json({error:'Technician profile not found'});res.json({data});}
async function updateProfile(req,res){res.json({data:await repo.updateProfile(req.user.id,req.body)});}
async function listJobs(req,res){res.json({data:await repo.listJobs(req.user,req.validatedQuery)});}
async function getJob(req,res){res.json({data:await service.ownedJob(req.params.jobId,req.user)});}
async function navigation(req,res){res.json({data:await service.navigation(req.params.jobId,req.user)});}
async function updateStatus(req,res){res.json({data:await service.updateStatus(req.params.jobId,req.body.status,req.body.notes,req.user)});}
async function addEvidence(req,res){res.status(201).json({data:await service.addEvidence(req.params.jobId,req.files,req.body,req.user)});}
async function addMaterial(req,res){res.status(201).json({data:await service.addMaterial(req.params.jobId,req.body,req.user)});}
async function shareLocation(req,res){res.status(201).json({data:await service.shareLocation(req.params.jobId,req.body,req.user)});}
async function requestOtp(req,res){res.status(201).json({data:await service.requestCompletionOtp(req.params.jobId,req.user)});}
async function confirm(req,res){res.json({data:await service.confirmCompletion(req.params.jobId,req.body,req.user)});}
async function notifications(req,res){res.json({data:(await repo.pool().query('SELECT id,channel,event_key AS "eventKey",title,body,data,read_at AS "readAt",created_at AS "createdAt" FROM notifications WHERE user_id=$1 ORDER BY id DESC LIMIT 100',[req.user.id])).rows});}
async function readNotification(req,res){await repo.pool().query('UPDATE notifications SET read_at=COALESCE(read_at,NOW()) WHERE id=$1 AND user_id=$2',[req.params.id,req.user.id]);const row=(await repo.pool().query('SELECT id,read_at AS "readAt" FROM notifications WHERE id=$1 AND user_id=$2',[req.params.id,req.user.id])).rows[0];if(!row)throw Object.assign(new Error('Notification not found'),{status:404});res.json(row);}
async function readAllNotifications(req,res){const result=await repo.pool().query('UPDATE notifications SET read_at=NOW() WHERE user_id=$1 AND read_at IS NULL',[req.user.id]);res.json({updated:result.rowCount});}
async function registerDevice(req,res){await require('../../database').registerDeviceToken(req.user.id,req.body.token,req.body.platform);res.status(201).json({registered:true});}
async function unregisterDevice(req,res){const result=await repo.pool().query('UPDATE device_tokens SET active=FALSE,last_seen_at=NOW() WHERE user_id=$1 AND token=$2',[req.user.id,req.body.token]);res.json({unregistered:Boolean(result.rowCount)});}
async function reviews(req,res){res.json(await require('../../services/reviewService').technician(req.user.id));}
async function createSiteRequest(req,res){res.status(201).json(await require('../services/siteRequestService').create(req.user,req.body));}
async function listSiteRequests(req,res){res.json(await require('../services/siteRequestService').list(req.user));}
async function deleteAccount(req,res){
  if(String(req.body.confirm||'').trim().toUpperCase()!=='DELETE')throw Object.assign(new Error('Type DELETE to confirm account deletion'),{status:422});
  const pool=repo.pool(),uid=req.user.id;
  await pool.query("UPDATE users SET status='deleted',email=CONCAT('deleted+',id,'+',UNIX_TIMESTAMP(),'@signfix.invalid'),mobile=NULL,updated_at=NOW() WHERE id=$1",[uid]);
  await pool.query('UPDATE technicians SET location_sharing=FALSE,last_latitude=NULL,last_longitude=NULL,last_location_at=NULL,emergency_contact=NULL WHERE user_id=$1',[uid]);
  await pool.query('UPDATE device_tokens SET active=FALSE WHERE user_id=$1',[uid]).catch(()=>{});
  if(req.user.jti&&req.user.exp)await pool.query('INSERT IGNORE INTO revoked_tokens(jti,user_id,expires_at) VALUES($1,$2,FROM_UNIXTIME($3))',[req.user.jti,uid,req.user.exp]);
  res.json({deleted:true,message:'Account has been deleted and personal details have been removed.'});
}
module.exports={deleteAccount,createSiteRequest,listSiteRequests,dashboard,profile,updateProfile,listJobs,getJob,navigation,updateStatus,addEvidence,addMaterial,shareLocation,requestOtp,confirm,notifications,readNotification,readAllNotifications,registerDevice,unregisterDevice,reviews};
