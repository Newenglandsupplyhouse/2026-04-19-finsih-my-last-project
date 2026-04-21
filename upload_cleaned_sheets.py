from __future__ import annotations

import json
import mimetypes
import os
import re
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib import error, request


ROOT = Path(__file__).resolve().parent
ENV_PATH = ROOT / ".env"
SOURCE_DIR = ROOT / "cleaned-product-sheets-v3"
MANIFEST_PATH = ROOT / "cleaned-product-sheets-v3-upload-manifest.json"


def load_env(path: Path) -> None:
    if not path.exists():
        return

    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        key = key.strip()
        value = value.strip().strip("'").strip('"')
        if key and key not in os.environ:
            os.environ[key] = value


def post_json(url: str, api_key: str, payload: dict[str, Any]) -> dict[str, Any]:
    req = request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with request.urlopen(req) as response:
        return json.loads(response.read().decode("utf-8"))


def upload_file(url: str, api_key: str, file_path: Path, purpose: str) -> dict[str, Any]:
    boundary = f"----CodexBoundary{uuid.uuid4().hex}"
    mime_type = mimetypes.guess_type(file_path.name)[0] or "text/markdown"
    file_bytes = file_path.read_bytes()

    body = []
    body.append(f"--{boundary}\r\n".encode("utf-8"))
    body.append(b'Content-Disposition: form-data; name="purpose"\r\n\r\n')
    body.append(f"{purpose}\r\n".encode("utf-8"))
    body.append(f"--{boundary}\r\n".encode("utf-8"))
    disposition = (
        f'Content-Disposition: form-data; name="file"; filename="{file_path.name}"\r\n'
    )
    body.append(disposition.encode("utf-8"))
    body.append(f"Content-Type: {mime_type}\r\n\r\n".encode("utf-8"))
    body.append(file_bytes)
    body.append(b"\r\n")
    body.append(f"--{boundary}--\r\n".encode("utf-8"))
    payload = b"".join(body)

    req = request.Request(
        url,
        data=payload,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Content-Length": str(len(payload)),
        },
        method="POST",
    )
    with request.urlopen(req) as response:
        return json.loads(response.read().decode("utf-8"))


def extract_source_url(file_path: Path) -> str | None:
    lines = file_path.read_text(encoding="utf-8", errors="ignore").splitlines()
    for index, line in enumerate(lines):
        if line.strip() != "Source URL":
            continue
        for candidate in lines[index + 1 :]:
            value = candidate.strip()
            if value:
                return value
    return None


@dataclass
class UploadResult:
    filename: str
    openai_file_id: str
    vector_store_file_id: str
    source_url: str | None


def main() -> None:
    load_env(ENV_PATH)

    api_key = os.environ.get("OPENAI_API_KEY")
    vector_store_id = os.environ.get("OPENAI_VECTOR_STORE_ID")
    if not api_key or not vector_store_id:
        raise SystemExit("Missing OPENAI_API_KEY or OPENAI_VECTOR_STORE_ID")

    files = sorted(SOURCE_DIR.glob("*.md"))
    results: list[UploadResult] = []

    for file_path in files:
        source_url = extract_source_url(file_path)
        try:
            uploaded_file = upload_file(
                "https://api.openai.com/v1/files",
                api_key,
                file_path,
                "assistants",
            )
            vector_store_file = post_json(
                f"https://api.openai.com/v1/vector_stores/{vector_store_id}/files",
                api_key,
                {
                    "file_id": uploaded_file["id"],
                    "attributes": {"source_url": source_url} if source_url else {},
                },
            )
        except error.HTTPError as exc:
            details = exc.read().decode("utf-8", errors="ignore")
            raise SystemExit(f"Upload failed for {file_path.name}: {details}") from exc

        results.append(
            UploadResult(
                filename=file_path.name,
                openai_file_id=uploaded_file["id"],
                vector_store_file_id=vector_store_file["id"],
                source_url=source_url,
            )
        )

    manifest = {
        "vector_store_id": vector_store_id,
        "uploaded_count": len(results),
        "files": [result.__dict__ for result in results],
    }
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
