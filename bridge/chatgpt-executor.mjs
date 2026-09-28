import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';

const emit=(x)=>process.stdout.write(JSON.stringify(x)+'\n');
const key=process.env.OPENAI_API_KEY||'';
const model=process.env.OPENAI_MODEL||'gpt-5.6';
if(!key){console.error('OPENAI_API_KEY não configurada.');process.exit(1);}
async function openai(pathname,options={}){
  const r=await fetch('https://api.openai.com/v1'+pathname,{...options,headers:{Authorization:'Bearer '+key,'Content-Type':'application/json',...(options.headers||{})}});
  const text=await r.text();let data;try{data=text?JSON.parse(text):{};}catch{data={raw:text};}
  if(!r.ok)throw Error(data?.error?.message||('OpenAI HTTP '+r.status));
  return data;
}
if(process.argv.includes('--status')){
  try{
    const m=await openai('/models/'+encodeURIComponent(model));
    console.log('ChatGPT '+m.id+' disponível');
    process.exit(0);
  }catch(e){
    console.error(e?.message||String(e));
    process.exit(1);
  }
}

let meta={};
try{meta=JSON.parse(Buffer.from(process.env.PONTE_JOB||'','base64').toString('utf8')||'{}');}catch{}
const workspace=path.resolve(meta.workspace||process.cwd());
const mode=meta.mode==='workspace-write'?'workspace-write':'read-only';
const additionalDirs=Array.isArray(meta.additionalDirs)?meta.additionalDirs:[];
const declaredRoots=[workspace,...additionalDirs.map(String)];
const roots=[];
for(const p of declaredRoots){
  const abs=path.resolve(p);
  if(!fs.existsSync(abs)||!fs.statSync(abs).isDirectory())throw Error('Pasta permitida indisponível: '+abs);
  roots.push(fs.realpathSync.native(abs));
}
const lower=(s)=>String(s).toLowerCase();
const inside=(real)=>roots.some(r=>{const a=lower(real),b=lower(r);return a===b||a.startsWith(b+path.sep);});
const candidate=(p)=>path.isAbsolute(String(p))?path.resolve(String(p)):path.resolve(workspace,String(p||'.'));
function existing(p){
  const abs=candidate(p);
  if(!fs.existsSync(abs))throw Error('Caminho não encontrado: '+abs);
  const real=fs.realpathSync.native(abs);
  if(!inside(real))throw Error('Caminho fora das pastas permitidas.');
  return real;
}
function writable(p){
  const abs=candidate(p);
  if(fs.existsSync(abs))return existing(abs);
  let probe=path.dirname(abs);
  while(!fs.existsSync(probe)){
    const next=path.dirname(probe);
    if(next===probe)break;
    probe=next;
  }
  if(!fs.existsSync(probe))throw Error('Não foi possível validar a pasta de destino.');
  const realParent=fs.realpathSync.native(probe);
  if(!inside(realParent))throw Error('Destino fora das pastas permitidas.');
  return abs;
}
function writeAllowed(){if(mode!=='workspace-write')throw Error('Esta tarefa está em modo somente leitura.');}
function smallText(file,max=250000){
  const b=fs.readFileSync(file);
  if(b.length>max)throw Error('Arquivo grande demais para leitura direta: '+b.length+' bytes.');
  if(b.includes(0))throw Error('Arquivo binário não suportado.');
  return b.toString('utf8');
}
function toolListDir(a){
  const dir=existing(a.path);
  if(!fs.statSync(dir).isDirectory())throw Error('Não é uma pasta.');
  return {path:dir,items:fs.readdirSync(dir,{withFileTypes:true}).slice(0,300).map(e=>({name:e.name,type:e.isDirectory()?'dir':e.isFile()?'file':e.isSymbolicLink()?'symlink':'other'}))};
}
function toolReadText(a){const file=existing(a.path);if(!fs.statSync(file).isFile())throw Error('Não é um arquivo.');return {path:file,text:smallText(file)};}
function toolSearchText(a){
  const root=existing(a.path),query=String(a.query||'');
  if(!query)throw Error('Busca vazia.');
  const results=[];let files=0;
  const skip=new Set(['node_modules','.git','.runtime','checkpoints']);
  function walk(dir,depth){
    if(depth>10||results.length>=100||files>=3000)return;
    for(const e of fs.readdirSync(dir,{withFileTypes:true})){
      if(results.length>=100||files>=3000)break;
      if(e.isSymbolicLink())continue;
      const p=path.join(dir,e.name);
      if(e.isDirectory()){
        if(!skip.has(e.name))walk(p,depth+1);
        continue;
      }
      if(!e.isFile())continue;
      files++;
      try{
        const st=fs.statSync(p);if(st.size>1000000)continue;
        const b=fs.readFileSync(p);if(b.includes(0))continue;
        const text=b.toString('utf8'),idx=text.toLocaleLowerCase().indexOf(query.toLocaleLowerCase());
        if(idx>=0){const before=text.slice(0,idx),line=before.split(/\r?\n/).length,preview=text.slice(Math.max(0,idx-120),Math.min(text.length,idx+query.length+220));results.push({path:p,line,preview});}
      }catch{}
    }
  }
  if(fs.statSync(root).isDirectory())walk(root,0);else{const t=smallText(root,1000000),idx=t.toLocaleLowerCase().indexOf(query.toLocaleLowerCase());if(idx>=0)results.push({path:root,line:t.slice(0,idx).split(/\r?\n/).length,preview:t.slice(Math.max(0,idx-120),idx+query.length+220)});}
  return {query,results,scannedFiles:files};
}
function toolWriteText(a){writeAllowed();const file=writable(a.path),content=String(a.content??'');if(Buffer.byteLength(content,'utf8')>1000000)throw Error('Conteúdo grande demais.');fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,content,'utf8');return {ok:true,path:file,bytes:Buffer.byteLength(content,'utf8')};}
function toolReplaceText(a){
  writeAllowed();const file=existing(a.path),oldText=String(a.old_text??''),newText=String(a.new_text??'');if(!oldText)throw Error('old_text vazio.');
  let text=smallText(file,2000000),count=0;
  if(a.replace_all){count=text.split(oldText).length-1;text=text.split(oldText).join(newText);}else{const i=text.indexOf(oldText);if(i>=0){text=text.slice(0,i)+newText+text.slice(i+oldText.length);count=1;}}
  if(count===0)throw Error('Trecho não encontrado.');fs.writeFileSync(file,text,'utf8');return {ok:true,path:file,replacements:count};
}
function toolCreateDir(a){writeAllowed();const dir=writable(a.path);fs.mkdirSync(dir,{recursive:true});return {ok:true,path:dir};}
function toolGit(kind){
  const args=kind==='status'?['-c','core.fsmonitor=false','status','--short']:['--no-pager','diff','--no-ext-diff','--no-textconv','HEAD','--'];
  const r=spawnSync('git',args,{cwd:workspace,encoding:'utf8',windowsHide:true,timeout:20000,maxBuffer:1024*1024});
  if(r.error)throw r.error;return {code:r.status,stdout:(r.stdout||'').slice(0,200000),stderr:(r.stderr||'').slice(0,50000)};
}
const tools=[
  {type:'function',name:'list_dir',description:'Lista arquivos e pastas dentro do projeto ou das pastas adicionais permitidas.',parameters:{type:'object',properties:{path:{type:'string'}},required:['path'],additionalProperties:false},strict:true},
  {type:'function',name:'read_text',description:'Lê um arquivo de texto permitido.',parameters:{type:'object',properties:{path:{type:'string'}},required:['path'],additionalProperties:false},strict:true},
  {type:'function',name:'search_text',description:'Procura texto recursivamente em arquivos permitidos.',parameters:{type:'object',properties:{path:{type:'string'},query:{type:'string'}},required:['path','query'],additionalProperties:false},strict:true},
  {type:'function',name:'write_text',description:'Cria ou sobrescreve um arquivo de texto. Só funciona no modo Editar projeto.',parameters:{type:'object',properties:{path:{type:'string'},content:{type:'string'}},required:['path','content'],additionalProperties:false},strict:true},
  {type:'function',name:'replace_text',description:'Substitui um trecho exato em um arquivo de texto. Só funciona no modo Editar projeto.',parameters:{type:'object',properties:{path:{type:'string'},old_text:{type:'string'},new_text:{type:'string'},replace_all:{type:'boolean'}},required:['path','old_text','new_text','replace_all'],additionalProperties:false},strict:true},
  {type:'function',name:'create_dir',description:'Cria uma pasta dentro das áreas permitidas. Só funciona no modo Editar projeto.',parameters:{type:'object',properties:{path:{type:'string'}},required:['path'],additionalProperties:false},strict:true},
  {type:'function',name:'git_status',description:'Mostra git status --short do projeto.',parameters:{type:'object',properties:{},required:[],additionalProperties:false},strict:true},
  {type:'function',name:'git_diff',description:'Mostra o diff Git atual do projeto.',parameters:{type:'object',properties:{},required:[],additionalProperties:false},strict:true}
];
function runTool(name,args){switch(name){case'list_dir':return toolListDir(args);case'read_text':return toolReadText(args);case'search_text':return toolSearchText(args);case'write_text':return toolWriteText(args);case'replace_text':return toolReplaceText(args);case'create_dir':return toolCreateDir(args);case'git_status':return toolGit('status');case'git_diff':return toolGit('diff');default:throw Error('Ferramenta desconhecida: '+name);}}
let task='';for await(const chunk of process.stdin)task+=chunk.toString('utf8');
if(!task.trim())throw Error('Tarefa vazia.');
const instructions=`Você é o executor ChatGPT da Ponte Git no PC autorizado do usuário. Responda em português. Trabalhe somente no projeto e nas pastas adicionais fornecidas pelas ferramentas. Respeite o modo ${mode}. Em modo read-only, não tente escrever. Em modo workspace-write, você pode criar e alterar arquivos apenas nas pastas permitidas. Não publique, não envie mensagens, não faça push, não altere configurações do sistema, não reinicie nem desligue o computador e não apague arquivos. Use as ferramentas para inspecionar antes de editar. Ao terminar, informe de forma objetiva o que fez, os arquivos alterados e qualquer limitação de verificação.`;
emit({type:'thread.started',thread_id:'chatgpt-'+crypto.randomUUID()});
try{
  let response=await openai('/responses',{method:'POST',body:JSON.stringify({model,reasoning:{effort:'medium'},instructions,input:task,tools,tool_choice:'auto',max_output_tokens:8192})});
  for(let step=0;step<24;step++){
    const calls=(response.output||[]).filter(x=>x.type==='function_call');
    if(!calls.length){
      const answer=(response.output||[]).flatMap(x=>x.type==='message'?(x.content||[]).filter(c=>c.type==='output_text').map(c=>c.text||''):[]).join('\n').trim()||'Execução concluída.';
      emit({type:'item.completed',item:{type:'agent_message',text:answer}});
      emit({type:'turn.completed',usage:response.usage||{}});
      process.exit(0);
    }
    const outputs=[];
    for(const call of calls){
      let args={};try{args=JSON.parse(call.arguments||'{}');}catch{}
      let result;
      try{result={ok:true,data:runTool(call.name,args)};}catch(e){result={ok:false,error:e?.message||String(e)};}
      const isChange=['write_text','replace_text','create_dir'].includes(call.name);
      if(isChange)emit({type:'item.completed',item:{type:'file_change',tool:call.name,args,result}});
      else emit({type:'item.completed',item:{type:'command_execution',command:'ChatGPT tool: '+call.name+' '+JSON.stringify(args),aggregated_output:JSON.stringify(result).slice(0,12000)}});
      outputs.push({type:'function_call_output',call_id:call.call_id,output:JSON.stringify(result)});
    }
    response=await openai('/responses',{method:'POST',body:JSON.stringify({model,reasoning:{effort:'medium'},instructions,previous_response_id:response.id,input:outputs,tools,tool_choice:'auto',max_output_tokens:8192})});
  }
  throw Error('Limite interno de etapas atingido.');
}catch(e){
  emit({type:'turn.failed',error:{message:e?.message||String(e)}});
  process.exit(1);
}
