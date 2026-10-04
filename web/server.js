// Tiny static frontend; calls the API relatively (/api/...) — same name, routed by path.
const http = require('http')
const page = `<!doctype html><title>Notes</title><h1>Notes</h1><ul id=n></ul>
<script>fetch('/api/notes').then(r=>r.json()).then(ns=>{n.innerHTML=ns.map(x=>'<li>'+x.body).join('')})</script>`
http.createServer((req, res) => {
  if (req.url === '/healthz') { res.end('ok'); return }
  res.setHeader('content-type', 'text/html'); res.end(page)
}).listen(3000, () => console.log('web on 3000'))
