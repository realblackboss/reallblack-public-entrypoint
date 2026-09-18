(() => {
'use strict';

const API='https://qfkcripudkcmsdxrhdbt.supabase.co/functions/v1/kael-v38-public-snapshot';
const CONTROL='https://qfkcripudkcmsdxrhdbt.supabase.co/functions/v1/kael-v38-control';
const REFRESH_MS=10000;
const LEASE_MS=14000;
const TAB_ID=(crypto.randomUUID?.()||Math.random().toString(36).slice(2));
const $=id=>document.getElementById(id);
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmtBytes=n=>{n=Number(n||0);return n>=1048576?(n/1048576).toFixed(1)+' MB/s':n>=1024?(n/1024).toFixed(0)+' KB/s':n+' B/s'};

let snap=null, selected=null, adminKey='', volume=0, quality='auto';
let refreshTimer=0, refreshAbort=null, refreshInFlight=false, lastSnapshotAt=0, isLeader=false, lastOrderKey='', statsTimer=0;
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

function qualityToken(q){
  if(typeof q==='string')return q;
  return String(q?.group||q?.name||q?.value||'');
}
function qualityScore(q){
  const s=String(q||'').toLowerCase();
  if(s==='chunked'||s.includes('source'))return 99999;
  const m=s.match(/(\d{3,4})p/);
  return m?Number(m[1]):0;
}
function applyQualityOne(player){
  if(!player)return;
  try{
    if(quality==='auto'){
      try{player.setQuality('auto')}catch{}
      return;
    }
    const qs=(player.getQualities?.()||[]).map(qualityToken).filter(Boolean).sort((a,b)=>qualityScore(a)-qualityScore(b));
    if(!qs.length)return;
    const target=quality==='minimum'?qs[0]:qs[Math.min(1,qs.length-1)];
    if(target)player.setQuality(target);
  }catch{}
}
function applyQuality(){for(const p of players.values())applyQualityOne(p.player)}

function updateDirectMetrics(){
  let ready=0,playing=0,kbps=0,drops=0;
  for(const p of players.values()){
    if(p.ready)ready++;
    if(p.playing)playing++;
    try{
      const s=p.player?.getPlaybackStats?.();
      if(s){
        kbps+=Number(s.playbackRate||0);
        drops+=Number(s.skippedFrames||0);
        if(Number(s.playbackRate||0)>0)p.playing=true;
      }
      if(p.player?.isPaused && p.player.isPaused()===false)p.playing=true;
    }catch{}
  }
  setText($('mCpu'),String(players.size));
  setText($('mOpen'),playing+'/'+players.size);
  if(kbps>0)setText($('mNet'),(kbps/1000).toFixed(1)+' Mbps');
  else setText($('mNet'),'-');
  setText($('mDrops'),String(Math.round(drops)));
  try{
    const mem=performance.memory?.usedJSHeapSize;
    setText($('mRam'),mem?Math.round(mem/1048576)+' MB':'-');
  }catch{setText($('mRam'),'-')}
}

function cleanupPlayer(id){
  const p=players.get(id);
  if(!p)return;
  try{p.host?.replaceChildren()}catch{}
  players.delete(id);
  updateDirectMetrics();
}

function cleanupAll(){
  clearTimeout(refreshTimer);
  clearInterval(statsTimer);
  try{refreshAbort?.abort()}catch{}
  for(const id of [...players.keys()])cleanupPlayer(id);
  try{
    const lease=JSON.parse(localStorage.getItem(leaseKey())||'null');
    if(lease?.id===TAB_ID)localStorage.removeItem(leaseKey());
  }catch{}
  try{channel?.close()}catch{}
}

function attachPlayer(t){
  if(players.has(t.tenant_id))return;
  const card=cards.get(t.tenant_id);
  if(!card)return;
  const host=card.playerHost, ov=card.overlay;
  const channelName=String(t.target_channel||'').replace(/^@/,'').trim();
  if(!channelName){
    setClass(ov,'hide',false);
    setText(ov,'CANAL NÃO CONFIGURADO');
    return;
  }
  if(!window.Twitch?.Player){
    setClass(ov,'hide',false);
    setText(ov,'CARREGANDO PLAYER TWITCH');
    setTimeout(()=>{if(!players.has(t.tenant_id))attachPlayer(t)},500);
    return;
  }
  const hostId='tw-'+String(t.tenant_id).replace(/[^a-zA-Z0-9_-]/g,'');
  host.id=hostId;
  host.replaceChildren();
  setClass(ov,'hide',false);
  setText(ov,'CONECTANDO TWITCH');
  try{
    const player=new Twitch.Player(hostId,{
      width:'100%',
      height:'100%',
      channel:channelName,
      parent:[location.hostname],
      autoplay:true,
      muted:volume===0
    });
    const entry={player,host,channel:channelName,ready:false,playing:false};
    players.set(t.tenant_id,entry);

    player.addEventListener(Twitch.Player.READY,()=>{
      entry.ready=true;
      try{
        player.setMuted(volume===0);
        player.setVolume(volume);
        applyQualityOne(player);
        player.play();
      }catch{}
      updateDirectMetrics();
    });
    player.addEventListener(Twitch.Player.PLAYING,()=>{
      entry.playing=true;
      setClass(ov,'hide',true);
      updateDirectMetrics();
    });
    player.addEventListener(Twitch.Player.ONLINE,()=>{
      setText(ov,'INICIANDO LIVE');
      try{
        player.setMuted(volume===0);
        player.play();
      }catch{}
    });
    player.addEventListener(Twitch.Player.OFFLINE,()=>{
      entry.playing=false;
      setClass(ov,'hide',false);
      setText(ov,'CANAL OFFLINE');
      updateDirectMetrics();
    });
    player.addEventListener(Twitch.Player.PLAYBACK_BLOCKED,()=>{
      setClass(ov,'hide',false);
      setText(ov,'CLIQUE NO PLAYER PARA REPRODUZIR');
    });
    updateDirectMetrics();
  }catch(e){
    setClass(ov,'hide',false);
    setText(ov,'ERRO PLAYER TWITCH');
    console.error('V38 Twitch player',t.tenant_id,e);
  }
}

function createCard(t){
  const article=document.createElement('article');
  article.className='card';
  article.dataset.id=t.tenant_id;
  article.innerHTML='<div class="cardhead"><i class="dot"></i><span class="cardtitle"></span><span class="state"></span></div><div class="media"><div class="twitch-host"></div><div class="overlay"></div></div><div class="meta"><div class="row"><span>Login</span><b class="login"></b></div><div class="row"><span>Sessão</span><span class="session"></span></div><div class="row"><span>Rota</span><span class="route"></span></div></div>';
  $('grid').appendChild(article);
  const ref={
    root:article,
    dot:article.querySelector('.dot'),
    title:article.querySelector('.cardtitle'),
    state:article.querySelector('.state'),
    playerHost:article.querySelector('.twitch-host'),
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
  setClass(c.dot,'ok',true);
  setText(c.title,'@'+(t.target_channel??'')+' | '+(t.display_name??'')+' | '+(t.network_mode??'')+' | '+(t.masked_ip??''));
  setText(c.state,'DIRETO');
  setText(c.login,t.login_state??'');
  c.login.className='login '+(t.login_state==='LOGIN OK'?'good':'warn');
  setText(c.session,t.session_state??'');
  setText(c.route,t.route_state??'');
  c.route.className='route '+(t.route_state==='HEALTHY'?'good':'bad');
  setClass(c.root,'selected',t.tenant_id===selected);
  const current=players.get(t.tenant_id);
  const desired=String(t.target_channel||'').replace(/^@/,'').trim();
  if(!current){
    setText(c.overlay,'CONECTANDO TWITCH');
    attachPlayer(t);
  }else if(current.channel!==desired && desired){
    current.channel=desired;
    setClass(c.overlay,'hide',false);
    setText(c.overlay,'TROCANDO CANAL');
    try{current.player.setChannel(desired)}catch{}
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
  updateDirectMetrics();

  const tenants=s.tenants||[];
  let ok=0,no=0;
  for(const t of tenants){if(t.login_state==='LOGIN OK')ok++;else if(t.login_state==='SEM LOGIN')no++}
  const total=s.counts?.tenants??tenants.length, pending=total-ok-no;
  const end=lotSize?Math.min(total,lotStart+lotSize-1):total;
  const lotInfo=lotSize?' | lote '+lotStart+'-'+end:'';
  const playing=[...players.values()].filter(p=>p.playing).length;
  setText($('summary'),total+' perfis'+lotInfo+' | '+playing+'/'+players.size+' vídeos tocando | '+ok+' login OK | '+pending+' login pendente | '+no+' sem login | vídeo Twitch → '+location.hostname);
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
  if(p){try{p.player.setMuted(volume===0);p.player.setVolume(volume);p.player.play()}catch{}}
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
window.KAEL_V38={
  openLot:openLotWindow,
  status:()=>({
    total:players.size,
    ready:[...players.values()].filter(p=>p.ready).length,
    playing:[...players.values()].filter(p=>p.playing).length,
    channels:[...players.values()].map(p=>({channel:p.channel,ready:p.ready,playing:p.playing}))
  })
};

async function enqueue(action,args={}){
  if(!adminKey)adminKey=prompt('Chave administrativa do KAEL Cloud:')||'';
  if(!adminKey)return;
  const r=await fetch(CONTROL,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({key:adminKey,op:'enqueue',action,args})});
  const j=await r.json();
  if(!r.ok){if(r.status===401)adminKey='';throw Error(j.error||'falha')}
  if(j?.mode==='CLOUD_PROVISIONED'){
    toast((j.created||1)+' perfil(is) criado(s) no cloud');
    await refresh({force:true});
  }else{
    toast(action+' enviado ao controle');
    setTimeout(()=>refresh({force:true}),2500);
  }
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
    try{
      p.player.setVolume(volume);
      p.player.setMuted(volume===0);
      if(volume>0)p.player.play();
    }catch{}
  }
};
$('loginBtn').onclick=()=>toast('Login isolado: estado sincronizado. A janela de autenticação remota segura ainda está sendo migrada para o cloud.');
$('loginNextBtn').onclick=()=>toast('Próximo login pendente: '+((snap?.tenants||[]).find(t=>t.login_state!=='LOGIN OK')?.display_name||'nenhum'));

if(channel){
  channel.onmessage=e=>{
    const m=e.data;
    if(m?.type==='snapshot' && m.from!==TAB_ID && m.at>=lastSnapshotAt)applySnapshot(m.data);
    else if(m?.type==='hello' && m.from!==TAB_ID && snap){
      try{channel.postMessage({type:'snapshot',from:TAB_ID,at:lastSnapshotAt||Date.now(),data:snap})}catch{}
    }
  };
  try{channel.postMessage({type:'hello',from:TAB_ID})}catch{}
}
window.addEventListener('storage',e=>{
  if(e.key===leaseKey())acquireLease();
});
window.addEventListener('pagehide',cleanupAll,{once:true});
window.addEventListener('beforeunload',cleanupAll,{once:true});

if(channel){
  setTimeout(()=>{if(!snap)refresh()},450);
  setTimeout(()=>{if(!snap)refresh({force:true})},2500);
}else refresh({force:true});
statsTimer=setInterval(updateDirectMetrics,5000);
scheduleRefresh();
})();
