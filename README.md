# Chatbase + OpenAI Vector Store Bridge

This project exposes a small API endpoint that Chatbase can call as a Custom Action.

## What it does

1. Chatbase collects the user's question.
2. Chatbase calls your API endpoint.
3. Your API searches an OpenAI vector store.
4. Your API returns JSON that Chatbase can use in its reply.

## Setup

1. Create a `.env` file from `.env.example`.

2. Set:

```bash
OPENAI_API_KEY=your_openai_api_key
OPENAI_VECTOR_STORE_ID=vs_...
PUBLIC_FILE_BASE_URL=https://docs.example.com/manuals
SHOPIFY_STORE_DOMAIN=your-store.myshopify.com
SHOPIFY_ADMIN_ACCESS_TOKEN=shpat_...
SHOPIFY_API_VERSION=2026-04
LOCAL_PDF_SOURCE_ROOT=G:\My Drive\Traderservice downloads
PORT=3010
MAX_RESULTS=3
MAX_CONTEXT_CHARS=4000
MAX_SNIPPET_CHARS=700
```

3. Start the server.

If you already have Node installed:

```bash
npm start
```

Or on this machine, use the included PowerShell launcher:

```powershell
.\run-bridge.ps1
```

4. Expose it publicly with your preferred tunnel or host.

For a quick public URL on this machine:

```powershell
.\start-live.ps1
```

If the bridge is already running on port `3000`, `start-live.ps1` now reuses it instead
of failing with `EADDRINUSE`.

To stop it later:

```powershell
.\stop-live.ps1
```

5. Verify health:

```bash
curl http://localhost:3010/health
```

## Railway deployment

This project is ready to deploy to Railway with the included
[`railway.json`](./railway.json).

1. Push this folder to a GitHub repository.
2. In Railway, create a new project from that repo.
3. Add these Railway variables:
   - `OPENAI_API_KEY`
   - `OPENAI_VECTOR_STORE_ID`
   - `MAX_RESULTS` optional
   - `MAX_CONTEXT_CHARS` optional
   - `MAX_SNIPPET_CHARS` optional
4. Do not set `PORT` manually on Railway unless you have a specific reason.
   Railway injects `PORT` automatically and the app already respects it.
5. Generate a Railway public domain under `Settings -> Networking`.

Railway will start the app with `node server.js` and use `/health` as the
deployment healthcheck.

## Render deployment

This project is also ready to deploy to Render.

Use the included [`render.yaml`](./render.yaml) or create a Render Web Service
manually with:

- Start command: `node server.js`
- Health check path: `/health`

Set these Render environment variables:

- `OPENAI_API_KEY`
- `OPENAI_VECTOR_STORE_ID`
- `PUBLIC_FILE_BASE_URL` optional
- `SHOPIFY_STORE_DOMAIN` optional
- `SHOPIFY_ADMIN_ACCESS_TOKEN` optional
- `SHOPIFY_API_VERSION` optional
- `MAX_RESULTS` optional
- `MAX_CONTEXT_CHARS` optional
- `MAX_SNIPPET_CHARS` optional

After deploy, use:

```text
https://your-render-domain.onrender.com/chatbase/vector-search
```

as the permanent Chatbase action URL instead of a temporary `trycloudflare.com`
tunnel.

## Chatbase configuration

In Chatbase:

1. Open your agent.
2. Go to `Actions` -> `Create action` -> `Custom action`.
3. Set:
   - Name: `search_knowledge_base`
   - When to use: Use this when the user asks about information stored in our knowledge base or documentation.
4. Add one input:
   - Name: `query`
   - Type: `text`
   - Description: The user's question to search in the knowledge base.
5. API request:
   - Method: `POST`
   - URL: `https://your-domain.com/chatbase/vector-search`
   - Header: `Content-Type: application/json`
   - JSON body:

```json
{
  "query": "{{query}}"
}
```

6. Choose `Full data access`.

## Expected response

The bridge returns JSON like:

```json
{
  "status": "success",
  "query": "What does our refund policy say?",
  "found": true,
  "answer_context": "1. Refunds are available within 30 days...",
  "documents": [
    {
      "file_id": "file_123",
      "filename": "refund-policy.pdf",
      "url": "https://example.com/refund-policy.pdf",
      "source_url": "https://example.com/refund-policy.pdf",
      "public_file_url": "https://docs.example.com/manuals/refund-policy.pdf",
      "bridge_url": "https://your-domain.com/chatbase/files/file_123",
      "format": "source-url"
    }
  ],
  "results": [
    {
      "file_id": "file_123",
      "filename": "refund-policy.pdf",
      "score": 0.91,
      "text": "Refunds are available within 30 days...",
      "source_url": "https://example.com/refund-policy.pdf",
      "original_url": "https://example.com/refund-policy.pdf",
      "file_url": "https://example.com/refund-policy.pdf",
      "bridge_file_url": "https://your-domain.com/chatbase/files/file_123",
      "public_file_url": "https://docs.example.com/manuals/refund-policy.pdf",
      "document_format": "source-url",
      "document_url": "https://example.com/refund-policy.pdf",
      "download_url": "https://your-domain.com/chatbase/files/file_123"
    }
  ]
}
```

If a source URL was stored on the vector-store file, the bridge returns it in
`source_url`, `file_url`, and `document_url`. If there is no stored source URL but
`PUBLIC_FILE_BASE_URL` is set, the bridge builds `public_file_url`, `file_url`, and
`document_url` from the original filename. The `download_url` now follows the same
customer-facing link, while `bridge_file_url` remains available as an internal bridge
route.

When that bridge file URL is opened, it now redirects to the stored `source_url` or
the configured public file URL whenever one exists. Only files with no external URL
available fall back to the bridge-hosted original file or, if needed, a downloadable
`.txt` export of the parsed document text.

## Shopify PDF sync

If you want every PDF already in the vector store to use a Shopify CDN URL, add:

- `SHOPIFY_STORE_DOMAIN`
- `SHOPIFY_ADMIN_ACCESS_TOKEN`
- optional `SHOPIFY_API_VERSION` default `2026-04`

Then run:

```powershell
powershell -ExecutionPolicy Bypass -File .\sync-pdfs-to-shopify.ps1
```

The script downloads each PDF from OpenAI, uploads it to Shopify Files, waits for the
Shopify CDN URL, and writes that URL back to the vector-store file metadata as
`source_url`, `shopify_cdn_url`, and `shopify_file_gid`.

If the OpenAI file purpose blocks direct binary download, the sync script will look for
the original PDF in `LOCAL_PDF_SOURCE_ROOT` by filename before falling back to OpenAI.

## Public bucket version

For a cleaner long-term setup, host the original PDFs in a public bucket or CDN while
preserving the filenames, then set:

```bash
PUBLIC_FILE_BASE_URL=https://docs.example.com/manuals
```

When that is set, the bridge builds the customer-facing document URL as:

```text
PUBLIC_FILE_BASE_URL/<encoded filename>
```

That means you do not need to backfill `source_url` on every vector-store file as long
as the hosted filenames match the OpenAI filenames exactly.

To generate a deduplicated upload manifest that matches vector-store PDF filenames to
your local originals, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\prepare-public-pdf-hosting.ps1
```

It writes [public-pdf-upload-manifest.json](./public-pdf-upload-manifest.json) with one
entry per unique PDF filename and the matching local path when found.

## Notes

- Chatbase's docs currently show Custom Actions expecting JSON requests and JSON responses.
- Chatbase's docs also mention a maximum response size of 20KB, so this bridge trims the returned context.
- This bridge also trims each result snippet so the action response stays small enough for Chatbase.
- This bridge uses only built-in Node APIs, so it does not require `npm install`.
- Railway is configured to start Node directly so the app receives `SIGTERM` cleanly during deploys.
- OpenAI vector stores support search and are used by the Retrieval and `file_search` workflows.
