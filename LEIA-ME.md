# House to Home

App para organizar a obra e o enxoval da casa. Funciona no iPhone como app instalado (Safari → Compartilhar → Adicionar à Tela de Início).

- **Site:** GitHub Pages (gratuito)
- **Conta e dados:** Supabase (gratuito), login com Google
- **Segurança:** cada pessoa só lê e grava as próprias linhas (`supabase/schema.sql`, regras RLS)
- `config.js` contém só a URL e a chave **pública** (anon) do Supabase. Nunca coloque a chave secreta de administrador.
