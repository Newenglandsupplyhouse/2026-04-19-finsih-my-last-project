# Render Deploy

Use this project for a stable Chatbase bridge URL instead of a temporary `trycloudflare.com` tunnel.

## What To Deploy

- Folder: `C:\Users\jason\Documents\Codex\2026-04-19-finsih-my-last-project`
- Start command: `node server.js`
- Health check path: `/health`

This repo now includes [render.yaml](./render.yaml), so Render can create the service with the right defaults.

## Render Steps

1. Create a GitHub repo from this folder if you have not already.
2. In Render, create a new `Blueprint` or `Web Service` from that repo.
3. If using the blueprint, Render will read `render.yaml`.
4. Set these environment variables in Render:
   - `OPENAI_API_KEY`
   - `OPENAI_VECTOR_STORE_ID`
   - `PUBLIC_FILE_BASE_URL` optional
   - `SHOPIFY_STORE_DOMAIN` optional
   - `SHOPIFY_ADMIN_ACCESS_TOKEN` optional
   - `SHOPIFY_API_VERSION` optional, default `2026-04`
   - `MAX_RESULTS` optional, default `3`
   - `MAX_CONTEXT_CHARS` optional, default `4000`
   - `MAX_SNIPPET_CHARS` optional, default `700`
5. Deploy the service.
6. Open `https://<your-render-domain>/health` and confirm it returns `ok: true`.

## Stable Chatbase URL

After deploy, set the Chatbase action URL to:

`https://<your-render-domain>/chatbase/vector-search`

Do not use the temporary `trycloudflare.com` URL after the Render deploy is live.

## Request Settings

- Method: `POST`
- Header: `Content-Type: application/json`
- Body:

```json
{
  "query": "{{query}}"
}
```
