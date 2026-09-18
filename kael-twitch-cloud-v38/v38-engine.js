(() => {
'use strict';

const API='https://qfkcripudkcmsdxrhdbt.supabase.co/functions/v1/kael-v37-public-snapshot';
const CONTROL='https://qfkcripudkcmsdxrhdbt.supabase.co/functions/v1/kael-v37-control';
const REFRESH_MS=10000;
const LEASE_MS=14000;
const TAB_ID=(crypto.randomUUID?.()||Math.random().toString(36).slice(2));
const $=id=>document.getElementById(id);
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmtBytes=n=>{n=Number(n||0);return n>=1048576?(n/1048576).toFixed(1)+' MB/s':n>=1024?(n/1024).toFixed(0)+' KB/s':n+' B/s'};

let snap=null, selected=null, adminKey='', volume=0, quality='auto', mediaBase=null;
let refreshTimer=0, refreshAbort=null, refreshInFlight=false, lastSnapshotAt=0, isLeader=false, lastOrderKey='';
const query=new URLSearchParams(location.search);
let lotStart=Math.max(1,Math.floor(Number(query.get('start')||1)));
let lotSize=query.has('size')?Math.max(1,Math.floor(Number(query.get('size')||50))):null;
const players=new Map();
const cards=new Map();
const tenantMap=new Map();
const channel=('BroadcastChannel' in window)?new BroadcastChannel('kael-v38-snapshot'):null;

function toast(s){const x=$('toast');x.textContent=s;x.style.display='block';clearTimeout(x._t);x._t=setTimeout(()=>x.style.display='none',4500)}

function setText(el,value){if(el && el.textContent!==String(value))el.textContent=String(value)}
function setClass(el,name,on){if(el)el.classList.toggle(name,!!on)}

function playerUrl(t,base){return base+'/tenant-hls/'+encodeURIComponent(t.tenant_id)+'/index.m3u8'}

function applyQualityOne(h){
  if(!h)return;
  try{
    if(quality==='auto')h.currentLevel=-1;
    else if(h.levels.length)h.currentLevel=quality==='minimum'?0:Math.min(1,h.levels.length-1);
  }catch{}
}
function applyQuality(){for(const p of players.values())applyQualityOne(p.hls)}

function cleanupPlayer(id){
  const p=players.get(id);
  if(!p)return;
  clearTimeout(p.retryTimer);
  try{p.abort?.abort()}catch{}
  try{p.hls?.destroy()}catch{}
  try{
    p.video.pause();
    p.video.removeAttribute('src');
    p.video.load();
  }catch{}
  players.delete(id);
}

function cleanupAll(){
  clearTimeout(refreshTimer);
  try{refreshAbort?.abort()}catch{}
  for(const id of [...players.keys()])cleanupPlayer(id);
  try{channel?.close()}catch{}
}

function attachPlayer(t,base){
  if(!base || players.has(t.tenant_id))return;
  const card=cards.get(t.tenant_id);
  if(!card)return;
  const video=card.video, ov=card.overlay;
  const url=playerUrl(t,base);
  let h=null, retry=0, retryTimer=0;
  const abort=new AbortController();

  video.autoplay=true;
  video.playsInline=true;
  video.muted=volume===0;
  video.volume=volume;
  video.preload='auto';

  const live=()=>{retry=0;setClass(ov,'hide',true)};
  const wait=()=>{setClass(ov,'hide',false);setText(ov,'CARREGANDO HLS')};
  const error=()=>{setClass(ov,'hide',false);setText(ov,'RECONECTANDO')};
  video.addEventListener('playing',live,{signal:abort.signal});
  video.addEventListener('waiting',wait,{signal:abort.signal});
  video.addEventListener('error',error,{signal:abort.signal});

  const scheduleRetry=()=>{
    clearTimeout(retryTimer);
    const delay=Math.min(12000,750*Math.pow(2,Math.min(retry++,4)));
    retryTimer=setTimeout(()=>{
      const p=players.get(t.tenant_id);
      if(!p)return;
      try{p.hls?.startLoad()}catch{}
      try{p.video.play().catch(()=>{})}catch{}
    },delay);
    const p=players.get(t.tenant_id);
    if(p)p.retryTimer=retryTimer;
  };

  if(window.Hls&&Hls.isSupported()){
    h=new Hls({
      enableWorker:true,
      lowLatencyMode:false,
      capLevelToPlayerSize:true,
      maxBufferLength:8,
      maxMaxBufferLength:12,
      backBufferLength:2,
      liveSyncDurationCount:3,
      liveMaxLatencyDurationCount:6,
      manifestLoadingMaxRetry:8,
      levelLoadingMaxRetry:6,
      fragLoadingMaxRetry:6
    });
    h.attachMedia(video);
    h.on(Hls.Events.MEDIA_ATTACHED,()=>h.loadSource(url));
    h.on(Hls.Events.MANIFEST_PARSED,()=>{applyQualityOne(h);video.play().catch(()=>{})});
    h.on(Hls.Events.ERROR,(_,d)=>{
      if(!d.fatal)return;
      if(d.type===Hls.ErrorTypes.MEDIA_ERROR){try{h.recoverMediaError()}catch{scheduleRetry()}}
      else scheduleRetry();
    });
  } else if(video.canPlayType('application/vnd.apple.mpegurl')){
    video.src=url;
    video.play().catch(()=>{});
  }

  players.set(t.tenant_id,{video,hls:h,base,url,abort,retryTimer});
}

function createCard(t){
  const article=document.createElement('article');
  article.className='card';
  article.dataset.id=t.tenant_id;
  article.innerHTML='<div class="cardhead"><i class="dot"></i><span class="cardtitle"></span><span class="state"></span></div><div class="media"><video muted></video><div class="overlay"></div></div><div class="meta"><div class="row"><span>Login</span><b class="login"></b></div><div class="row"><span>Sessão</span><span class="session"></span></div><div class="row"><span>Rota</span><span class="route"></span></div></div>';
  $('grid').appendChild(article);
  const ref={
    root:article,
    dot:article.querySelector('.dot'),
    title:article.querySelector('.cardtitle'),
    state:article.querySelector('.state'),
    video:article.querySelector('video'),
    overlay:article.querySelector('.overlay'),
    login:article.querySelector('.login'),
    session:article.querySelector('.session'),
    route:article.querySelector('.route')
  };
  cards.set(t.tenant_id,ref);
  return ref;
}

function updateCard(t){
  const c=cards.get(t.tenant_id)||createCard(t);
  setClass(c.dot,'ok',!!t.worker_online);
  setText(c.title,'@'+(t.target_channel??'')+' | '+(t.display_name??'')+' | '+(t.network_mode??'')+' | '+(t.masked_ip??''));
  setText(c.state,t.state??'');
  setText(c.login,t.login_state??'');
  c.login.className='login '+(t.login_state==='LOGIN OK'?'good':'warn');
  setText(c.session,t.session_state??'');
  setText(c.route,t.route_state??'');
  c.route.className='route '+(t.route_state==='HEALTHY'?'good':'bad');
  setClass(c.root,'selected',t.tenant_id===selected);
  if(!mediaBase){
    setClass(c.overlay,'hide',false);
    setText(c.overlay,'SEM GATEWAY DE MÍDIA');
  } else if(!players.has(t.tenant_id)){
    setText(c.overlay,'CONECTANDO HLS');
    attachPlayer(t,mediaBase);
  }
}

function activeTenants(s){
  const all=s.tenants||[];
  if(!lotSize)return all;
  return all.slice(lotStart-1,lotStart-1+lotSize);
}

function reconcileTenants(s){
  const list=activeTenants(s);
  tenantMap.clear();
  for(const t of list)tenantMap.set(t.tenant_id,t);

  for(const id of [...cards.keys()]){
    if(!tenantMap.has(id)){
      cleanupPlayer(id);
      cards.get(id)?.root.remove();
      cards.delete(id);
    }
  }

  const nextBase=s.media_base_url||null;
  if(nextBase!==mediaBase){
    mediaBase=nextBase;
    for(const id of [...players.keys()])cleanupPlayer(id);
  }

  for(const t of list)updateCard(t);
  const orderKey=list.map(t=>t.tenant_id).join('|');
  if(orderKey!==lastOrderKey){
    const frag=document.createDocumentFragment();
    for(const t of list){
      const c=cards.get(t.tenant_id);
      if(c)frag.appendChild(c.root);
    }
    if(frag.childNodes.length)$('grid').appendChild(frag);
    lastOrderKey=orderKey;
  }
}

function updateMetrics(s){
  setText($('mProfiles'),s.counts?.tenants??0);
  const ram=s.metrics?.kael_ram_mb;
  setText($('mRam'),ram==null?'-':(ram>=1024?(ram/1024).toFixed(1)+' GB':ram+' MB'));
  setText($('mCpu'),s.metrics?.cpu_pct==null?'-':s.metrics.cpu_pct+'%');
  setText($('mNet'),fmtBytes(s.metrics?.net_bps));
  setText($('mOpen'),s.metrics?.hls_probe_ms==null?'-':(s.metrics.hls_probe_ms/1000).toFixed(2)+' s');
  setText($('mDrops'),s.metrics?.drops??'-');

  const tenants=s.tenants||[];
  let ok=0,no=0;
  for(const t of tenants){if(t.login_state==='LOGIN OK')ok++;else if(t.login_state==='SEM LOGIN')no++}
  const total=s.counts?.tenants??tenants.length, pending=total-ok-no;
  const end=lotSize?Math.min(total,lotStart+lotSize-1):total;
  const lotInfo=lotSize?' | lote '+lotStart+'-'+end:'';
  setText($('summary'),total+' perfis'+lotInfo+' | '+(s.metrics?.sources??0)+' origens isoladas | '+ok+' login OK | '+pending+' login pendente | '+no+' sem login | '+(s.metrics?.fps??'-')+' FPS | '+(s.metrics?.pipelines??0)+' pipelines | worker '+(s.counts?.online_workers?'ONLINE':'OFFLINE'));
}

function applySnapshot(s,{broadcast=false}={}){
  if(!s || !Array.isArray(s.tenants))return;
  snap=s;
  lastSnapshotAt=Date.now();
  reconcileTenants(s);
  updateMetrics(s);
  filterCards();
  if(broadcast && channel)try{channel.postMessage({type:'snapshot',from:TAB_ID,at:lastSnapshotAt,data:s})}catch{}
}

function filterCards(){
  const q=$('search').value.trim().toLowerCase();
  for(const [id,c] of cards){
    const t=tenantMap.get(id);
    const hay=((t?.display_name||'')+' '+(t?.target_channel||'')+' '+(t?.masked_ip||'')+' '+(t?.network_mode||'')).toLowerCase();
    c.root.style.display=!q||hay.includes(q)?'':'none';
  }
}

function leaseKey(){return 'kael-v38-refresh-leader'}
function acquireLease(){
  const now=Date.now();
  let lease=null;
  try{lease=JSON.parse(localStorage.getItem(leaseKey())||'null')}catch{}
  if(!lease || lease.expires<now || lease.id===TAB_ID){
    try{localStorage.setItem(leaseKey(),JSON.stringify({id:TAB_ID,expires:now+LEASE_MS}))}catch{}
    isLeader=true;
  }else isLeader=false;
  return isLeader;
}

async function refresh({force=false}={}){
  if(refreshInFlight)return;
  if(!force && !acquireLease()){
    if(Date.now()-lastSnapshotAt<REFRESH_MS*2)return;
  }
  refreshInFlight=true;
  try{
    refreshAbort?.abort();
    refreshAbort=new AbortController();
    const r=await fetch(API,{cache:'no-store',signal:refreshAbort.signal});
    if(!r.ok)throw Error('HTTP '+r.status);
    const data=await r.json();
    applySnapshot(data,{broadcast:true});
  }catch(e){
    if(e.name!=='AbortError')toast('Falha cloud: '+e.message);
  }finally{
    refreshInFlight=false;
  }
}

function scheduleRefresh(){
  clearTimeout(refreshTimer);
  refreshTimer=setTimeout(async()=>{
    await refresh();
    scheduleRefresh();
  },REFRESH_MS);
}

function focus(){
  if(!selected){toast('Selecione um perfil primeiro.');return}
  document.body.classList.add('focus');
  for(const [id,c] of cards)setClass(c.root,'selected',id===selected);
  const p=players.get(selected);
  if(p){p.video.muted=volume===0;p.video.volume=volume}
}
function closeFocus(){document.body.classList.remove('focus')}

function readLotInputs(){
  const start=Math.max(1,Math.floor(Number($('lotStart')?.value)||1));
  const size=Math.max(1,Math.floor(Number($('lotSize')?.value)||50));
  return {start,size};
}
function makeLotUrl(start,size){
  const u=new URL(location.href);
  u.searchParams.set('start',String(start));
  u.searchParams.set('size',String(size));
  return u;
}
function applyLot(){
  const {start,size}=readLotInputs();
  location.href=makeLotUrl(start,size).href;
}
function openLotWindow(startArg,sizeArg){
  const v=(startArg&&sizeArg)?{start:Math.max(1,Math.floor(Number(startArg))),size:Math.max(1,Math.floor(Number(sizeArg)))}:readLotInputs();
  const u=makeLotUrl(v.start,v.size);
  const w=window.open(u.href,'kael-v38-lot-'+v.start+'-'+v.size,'popup=yes,width=1500,height=950,resizable=yes,scrollbars=yes');
  if(!w)toast('O navegador bloqueou a nova janela. Libere pop-ups para este painel.');
  return w;
}
window.KAEL_V38={openLot:openLotWindow};

async function enqueue(action,args={}){
  if(!adminKey)adminKey=prompt('Chave administrativa do KAEL Cloud:')||'';
  if(!adminKey)return;
  const r=await fetch(CONTROL,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({key:adminKey,op:'enqueue',action,args})});
  const j=await r.json();
  if(!r.ok){if(r.status===401)adminKey='';throw Error(j.error||'falha')}
  toast(action+' enviado ao worker');
  setTimeout(()=>refresh({force:true}),2500);
}

if($('lotStart'))$('lotStart').value=String(lotStart);
if($('lotSize'))$('lotSize').value=String(lotSize||50);
if($('lotBtn'))$('lotBtn').onclick=applyLot;
if($('lotWindowBtn'))$('lotWindowBtn').onclick=()=>openLotWindow();

$('grid').addEventListener('click',e=>{
  const card=e.target.closest('.card');
  if(!card)return;
  selected=card.dataset.id;
  for(const [id,c] of cards)setClass(c.root,'selected',id===selected);
});
$('search').addEventListener('input',filterCards);
$('refreshBtn').onclick=()=>refresh({force:true});
$('focusBtn').onclick=focus;
$('closeBtn').onclick=closeFocus;
$('gridBtn').onclick=closeFocus;
$('addBtn').onclick=()=>enqueue('ADD_PROFILE',{channel:'reallbllack'}).catch(e=>toast(e.message));
$('manualBtn').onclick=()=>{const c=$('channel').value.trim().replace(/^@/,'');if(!c)return toast('Informe o @ do canal.');enqueue('ADD_PROFILE',{channel:c}).catch(e=>toast(e.message))};
$('scaleBtn').onclick=()=>{const c=$('channel').value.trim().replace(/^@/,'');const n=Math.max(1,Number($('qty').value||1));if(!c)return toast('Informe o @ do canal.');enqueue('ADD_SCALE',{channel:c,count:n}).catch(e=>toast(e.message))};
$('qualityBtn').onclick=()=>{
  quality=quality==='auto'?'low':quality==='low'?'minimum':'auto';
  $('qualityBtn').textContent='QUALIDADE: '+(quality==='auto'?'AUTO':quality==='low'?'BAIXA':'MÍNIMA');
  applyQuality();
};
$('volumeBtn').onclick=()=>{
  volume=volume===0?.25:volume===.25?.5:volume===.5?1:0;
  $('volumeBtn').textContent=volume===0?'VOLUME: MUDO':'VOLUME: '+Math.round(volume*100)+'%';
  for(const p of players.values()){
    p.video.volume=volume;p.video.muted=volume===0;
    if(volume>0)p.video.play().catch(()=>{});
  }
};
$('loginBtn').onclick=()=>toast('Login isolado: estado sincronizado. A janela de autenticação remota segura ainda está sendo migrada para o cloud.');
$('loginNextBtn').onclick=()=>toast('Próximo login pendente: '+((snap?.tenants||[]).find(t=>t.login_state!=='LOGIN OK')?.display_name||'nenhum'));

if(channel){
  channel.onmessage=e=>{
    const m=e.data;
    if(m?.type==='snapshot' && m.from!==TAB_ID && m.at>=lastSnapshotAt)applySnapshot(m.data);
  };
}
window.addEventListener('storage',e=>{
  if(e.key===leaseKey())acquireLease();
});
window.addEventListener('pagehide',cleanupAll,{once:true});
window.addEventListener('beforeunload',cleanupAll,{once:true});

refresh({force:true});
scheduleRefresh();
})();
