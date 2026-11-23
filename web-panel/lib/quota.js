const db = require('../db/database');
const format = require('./format');

function getActiveClients(resellerId) {
  return db.prepare('SELECT * FROM clients WHERE reseller_id = ? AND deleted = 0').all(resellerId);
}

function getAllocatedQuotaSum(resellerId) {
  const row = db.prepare(
    `SELECT COALESCE(SUM(quota_gb), 0) AS total FROM clients WHERE reseller_id = ? AND deleted = 0 AND quota_gb IS NOT NULL`
  ).get(resellerId);
  return row.total;
}

// Somme des connexions simultanées allouées aux clients SSH
function getAllocatedConnectionsSum(resellerId, excludeClientId) {
  const row = db.prepare(
    `SELECT COALESCE(SUM(max_connections), 0) AS total FROM clients
     WHERE reseller_id = ? AND deleted = 0 AND type = 'ssh' AND id != ?`
  ).get(resellerId, excludeClientId || -1);
  return row.total;
}

function getResellerStats(reseller) {
  const active = getActiveClients(reseller.id);
  const allocated = getAllocatedQuotaSum(reseller.id);
  const allocatedConnections = getAllocatedConnectionsSum(reseller.id);

  const clientsLib = require('./clients');
  const system = require('./system');
  const onlineCounts = system.getOnlineSshCounts();

  let consumedActiveGb = 0;
  let onlineTotal = 0;
  let lockedCount = 0;
  let expiredCount = 0;

  // Calcul du trafic réel des clients actifs
  const clientsWithLive = active.map((c) => {
    const usageGb = clientsLib.clientUsageGb(c);
    if (usageGb != null) consumedActiveGb += usageGb;
    const online = c.type === 'ssh' ? (onlineCounts.get(c.identifier) || 0) : null;
    if (online) onlineTotal += Math.min(online, c.max_connections || online);
    if (c.status !== 'active') lockedCount += 1;
    if (c.status === 'locked_expired') expiredCount += 1;
    return { ...c, _online: online, usageGb: usageGb };
  });

  // Prise en compte également de la consommation des comptes Surfeo/App liés au revendeur
  try {
    const appAccounts = db.prepare('SELECT username FROM app_accounts WHERE reseller_id = ?').all(reseller.id);
    for (const a of appAccounts) {
      if (a.username) {
        const bytes = system.readSshUsageBytes(a.username);
        if (bytes > 0) consumedActiveGb += bytes / Math.pow(1024, 3);
      }
    }
  } catch {}

  // Consommation réelle totale du revendeur (comptage réel)
  const consumedTotalGb = Math.max(0, consumedActiveGb + (reseller.consumed_quota_gb || 0) - (reseller.quota_reset_offset_gb || 0));

  // Quota réel restant
  const remainingRealGb = reseller.data_quota_gb != null 
    ? Math.max(0, reseller.data_quota_gb - consumedTotalGb) 
    : null;

  return {
    activeClientCount: active.length,
    onlineClientCount: onlineTotal,
    lockedClientCount: lockedCount,
    expiredClientCount: expiredCount,
    allocatedQuotaGb: allocated,
    consumedByDeletedGb: reseller.consumed_quota_gb || 0,
    consumedTotalGb: consumedTotalGb,
    remainingRealGb: remainingRealGb,
    totalCommittedGb: consumedTotalGb, // Aligné sur la consommation réelle
    allocatedConnections: allocatedConnections,
    clients: clientsWithLive
  };
}

// Vérifie que la somme des connexions simultanées ne dépasse pas max_users
function assertConnectionsWithinLimit(reseller, maxConnections, excludeClientId) {
  const already = getAllocatedConnectionsSum(reseller.id, excludeClientId);
  const projected = already + (maxConnections || 0);
  if (projected > reseller.max_users) {
    const remaining = Math.max(0, reseller.max_users - already);
    throw new Error(
      `Limite de connexions simultanées atteinte : la somme des limites de connexion de vos comptes SSH ne peut pas dépasser ${reseller.max_users}. Il vous reste ${remaining} connexion(s) disponible(s) à répartir.`
    );
  }
}

// Vérifie si le revendeur a le droit de créer ce client selon son quota réel
function assertCanCreateClient(reseller, { quotaGb, protocols, maxConnections, type }) {
  if (reseller.status !== 'active') {
    throw new Error('Votre compte reseller est verrouillé, vous ne pouvez pas créer de nouveaux comptes.');
  }

  const stats = getResellerStats(reseller);
  if (stats.activeClientCount >= reseller.max_users) {
    throw new Error(`Limite atteinte : votre compte permet au maximum ${reseller.max_users} utilisateur(s) actif(s).`);
  }

  const allowedProtocols = JSON.parse(reseller.protocols || '[]');
  for (const p of protocols || []) {
    if (!allowedProtocols.includes(p)) {
      throw new Error(`Protocole non autorisé pour votre compte : ${p}`);
    }
  }

  if (type === 'ssh') {
    assertConnectionsWithinLimit(reseller, maxConnections);
  }

  // Si le revendeur a un quota illimité, aucune restriction de quota
  if (reseller.data_quota_gb == null) {
    return;
  }

  // Comptage réel : vérification de l'enveloppe globale restante
  const remainingReal = stats.remainingRealGb != null ? stats.remainingRealGb : Math.max(0, reseller.data_quota_gb - stats.consumedTotalGb);
  if (remainingReal <= 0) {
    throw new Error(`Quota insuffisant : votre enveloppe totale de données (${reseller.data_quota_gb} Go) est entièrement consommée (0 octets restants).`);
  }

  // Si un quota spécifique est demandé pour ce client, vérifier qu'il ne dépasse pas le restant réel
  if (quotaGb != null && quotaGb > 0 && quotaGb > remainingReal) {
    throw new Error(`Quota insuffisant : le quota demandé (${quotaGb} Go) dépasse votre quota restant disponible (${format.formatDataSize(remainingReal, 'fr')}).`);
  }
}

module.exports = {
  getActiveClients,
  getAllocatedQuotaSum,
  getAllocatedConnectionsSum,
  getResellerStats,
  assertCanCreateClient,
  assertConnectionsWithinLimit
};
