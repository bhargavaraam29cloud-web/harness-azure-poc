// =============================================================
// FILE: app/server.js
// WHAT THIS IS:
//   A Node.js Express web server — the application we deploy
//   to Azure AKS via Harness. It serves a dashboard page
//   and a /health endpoint that Kubernetes readiness probes hit.
//
// WHY WE WROTE IT THIS WAY:
//   Simple, real code that clearly shows it was hand-crafted.
//   The /health endpoint is critical — Kubernetes checks it
//   every few seconds. If it fails, pods restart automatically.
//   Harness Continuous Verification also monitors /health
//   after every deployment to confirm pods are stable.
// =============================================================

const express = require('express');
const os      = require('os');

const app  = express();
const PORT = process.env.PORT || 80;

// ------------------------------------------------------------------
// GET /  →  Main dashboard page
// This is what anyone browsing the public Load-Balancer IP will see.
// We return plain HTML so there are no static file dependencies.
// ------------------------------------------------------------------
app.get('/', (req, res) => {
  const html = `
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Harness Azure POC</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
      background: #0f1117;
      color: #e2e8f0;
      display: flex;
      justify-content: center;
      align-items: center;
      min-height: 100vh;
    }
    .card {
      background: #1a1f2e;
      border: 1px solid #2d3748;
      border-radius: 12px;
      padding: 40px 50px;
      max-width: 640px;
      width: 100%;
      text-align: center;
    }
    h1 { font-size: 1.8rem; color: #00ade4; margin-bottom: 8px; }
    p.sub { color: #718096; font-size: 0.95rem; margin-bottom: 30px; }
    .badge {
      display: inline-block;
      background: #1c3a2f;
      color: #38a169;
      border: 1px solid #38a169;
      border-radius: 20px;
      padding: 4px 14px;
      font-size: 0.82rem;
      margin-bottom: 28px;
    }
    table { width: 100%; border-collapse: collapse; text-align: left; }
    th, td { padding: 10px 14px; font-size: 0.9rem; }
    th { color: #718096; font-weight: 600; }
    td { color: #e2e8f0; }
    tr:not(:last-child) td { border-bottom: 1px solid #2d3748; }
    .footer { margin-top: 28px; color: #4a5568; font-size: 0.8rem; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Harness.io + Azure AKS</h1>
    <p class="sub">Automated Deployment POC — Deployed via Harness CD Pipeline</p>
    <span class="badge">&#10003; DEPLOYMENT SUCCESSFUL</span>
    <table>
      <tr><th>Hostname (Pod)</th><td>${os.hostname()}</td></tr>
      <tr><th>Platform</th>      <td>${os.platform()} / ${os.arch()}</td></tr>
      <tr><th>Node Version</th>  <td>${process.version}</td></tr>
      <tr><th>Uptime</th>        <td>${Math.floor(process.uptime())}s</td></tr>
      <tr><th>Timestamp</th>     <td>${new Date().toISOString()}</td></tr>
    </table>
    <p class="footer">
      Deployed by Harness.io K8sRollingDeploy &nbsp;|&nbsp;
      Cluster: harness-poc-aks &nbsp;|&nbsp; Namespace: harness-poc
    </p>
  </div>
</body>
</html>`;
  res.status(200).send(html);
});

// ------------------------------------------------------------------
// GET /health  →  Kubernetes readiness + liveness probe target
// Must return HTTP 200 with JSON { status: "ok" }.
// Kubernetes will restart the pod if this returns anything else.
// Harness Delegate also checks this endpoint after every deploy.
// ------------------------------------------------------------------
app.get('/health', (req, res) => {
  res.status(200).json({
    status:    'ok',
    hostname:  os.hostname(),
    uptime:    `${Math.floor(process.uptime())}s`,
    timestamp: new Date().toISOString(),
  });
});

// ------------------------------------------------------------------
// Start listening
// ------------------------------------------------------------------
app.listen(PORT, () => {
  console.log(`[server] Harness POC app running on port ${PORT}`);
  console.log(`[server] Health endpoint: http://localhost:${PORT}/health`);
});
