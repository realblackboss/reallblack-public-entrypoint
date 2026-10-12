# Instagram REALLBLLACK — navegador na nuvem, sem PC ligado

## O que é
Um Codespace privado do GitHub executa Chromium + desktop virtual e oferece uma interface no navegador do celular via noVNC. **Não usa TinyFish, RustDesk, Meta API, VPS pago ou o PC ligado** durante o uso.

### Ativar
1. Na página do repositório, escolha a branch `instagram-free-cloud-v1`.
2. Selecione **Code > Codespaces > Create codespace on instagram-free-cloud-v1** (escolha a máquina de 2 núcleos).
3. Aguarde a imagem do container construir e iniciar; na primeira vez pode levar alguns minutos.
4. Em **PORTS / PORTAS**, encontre `6080`. Confirme que o campo Visibility está definido como **Private**, nunca Public.
5. Abra a URL da porta 6080 e acrescente `/vnc.html?autoconnect=1`, se necessário.
6. Quando pedir a senha VNC, volte ao Terminal do Codespace e execute: `cat .ig-local-private/vnc-password`.
7. Faça login normalmente no Instagram dentro do Chromium remoto, concluindo eventual autenticação de dois fatores.

### Reutilizar a sessão
Abra seu Codespace existente em `https://github.com/codespaces`. Se ele estiver parado, clique Resume. O Chrome abre com o mesmo diretório de perfil. A sessão depende das políticas do Instagram e poderá exigir novo login.
**Não apague o Codespace para manter seu perfil e histórico.** O conteúdo persistido no Codespace não é um backup externo.

### Não pagar
GitHub Free para pessoa física inclui 120 horas-núcleo de processamento por mês (máquina de 2 núcleos = aproximadamente 60 horas reais/mês) e 15 GB-mês de armazenamento. Consulte o painel GitHub Billing antes e durante o uso. **Verifique que não há forma de pagamento ou que o orçamento está em zero**, para que o uso pare ao atingir a quota, em vez de gerar cobrança. Um Codespace fica parado quando ocioso; não é servidor 24 horas.
Se precisar de navegação contínua ilimitada, o GitHub Free não atende.

### Segurança
- **Este repositório é público**, mas apenas scripts e configurações sem informações pessoais são versionados.
- O navegador armazena cookies de sessão somente em `.ig-local-private/chrome-profile` dentro do Codespace, ignorado pelo Git.
- A porta encaminhada **precisa permanecer Private**. Nunca envie a URL do túnel ou a senha VNC para terceiros.
- O VNC usa uma segunda senha aleatória (máximo de oito caracteres no protocolo antigo) e só escuta na interface local do container.
- Instagram pode solicitar novas autenticações ou restringir o uso automatizado. Não utilize automações em massa nem técnicas de evasão.
- Para abandonar a sessão, exclua manualmente o Codespace (isso também destrói o perfil remoto).
- Não habilitamos ações automáticas de publicação ou mensagens.

### Diagnóstico
No Terminal Codespaces: `bash .devcontainer/start-instagram.sh`
Ver logs: `tail -n 80 .ig-local-private/logs/*.log`
Testar HTTP: `curl -I http://localhost:6080/vnc.html`

### Limites técnicos
Este é um protótipo criado em branch isolada, NÃO testado em um Codespace efetivamente iniciado ainda. É necessária a sua autorização GitHub para criar e abrir o Codespace e seu login Instagram no navegador remoto. O ChatGPT só controla essa interface quando você autoriza um navegador em Work; não executa operações contínuas sozinho.
