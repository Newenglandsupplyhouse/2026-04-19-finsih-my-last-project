from __future__ import annotations

import argparse
import html
import json
import re
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse


SKIP_TAGS = {
    "script",
    "style",
    "svg",
    "noscript",
    "iframe",
    "canvas",
    "form",
    "button",
    "input",
    "select",
    "option",
    "textarea",
}

BLOCK_TAGS = {
    "address",
    "article",
    "aside",
    "blockquote",
    "br",
    "caption",
    "div",
    "dl",
    "dt",
    "dd",
    "fieldset",
    "figcaption",
    "figure",
    "footer",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "header",
    "hr",
    "li",
    "main",
    "nav",
    "ol",
    "p",
    "pre",
    "section",
    "table",
    "tbody",
    "td",
    "tfoot",
    "th",
    "thead",
    "tr",
    "ul",
}

META_DESCRIPTION_KEYS = {
    "description",
    "og:description",
    "twitter:description",
}

TITLE_SUFFIXES = (
    " | Honeywell",
    " | Honeywell Building Automation",
    " - Honeywell Home",
)

ERROR_PATTERNS = (
    "multiple choices",
    "not found on this server",
    "access denied",
    "page not found",
)

BAD_TITLE_PATTERNS = (
    "404",
    "building automation",
    "you searched for",
    "videos",
    "video",
    "selection tools",
    "support",
    "home",
    "grundfos india",
    "hydronic solutions",
    "ie11 deprecation",
)

BAD_URL_PATTERNS = (
    "/home",
    "/videos",
    "/videos-2",
    "/selection-tools",
    "/support/",
)


class ProductSheetParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.skip_depth = 0
        self.title_parts: list[str] = []
        self.in_title = False
        self.meta: dict[str, str] = {}
        self.links: dict[str, str] = {}
        self.body_parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag = tag.lower()
        attrs_dict = {key.lower(): value for key, value in attrs if key}

        if tag in SKIP_TAGS:
            self.skip_depth += 1
            return

        if tag == "title":
            self.in_title = True

        if tag == "meta":
            name = (attrs_dict.get("name") or attrs_dict.get("property") or "").strip().lower()
            content = (attrs_dict.get("content") or "").strip()
            if name and content:
                self.meta[name] = content

        if tag == "link":
            rel = (attrs_dict.get("rel") or "").strip().lower()
            href = (attrs_dict.get("href") or "").strip()
            if rel and href:
                self.links[rel] = href

        if tag in BLOCK_TAGS:
            self.body_parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()

        if tag in SKIP_TAGS and self.skip_depth:
            self.skip_depth -= 1
            return

        if tag == "title":
            self.in_title = False

        if tag in BLOCK_TAGS:
            self.body_parts.append("\n")

    def handle_data(self, data: str) -> None:
        if self.skip_depth:
            return

        text = html.unescape(data)
        if self.in_title:
            self.title_parts.append(text)
            return

        if text.strip():
            self.body_parts.append(text)

    def extract(self) -> dict[str, str]:
        return {
            "title": clean_title("".join(self.title_parts)),
            "description": first_non_empty(
                self.meta.get(key, "") for key in META_DESCRIPTION_KEYS
            ),
            "canonical_url": self.links.get("canonical", ""),
            "body_text": normalize_body("".join(self.body_parts)),
        }


def first_non_empty(values) -> str:
    for value in values:
        if value and value.strip():
            return value.strip()
    return ""


def clean_title(value: str) -> str:
    title = compact_whitespace(value)
    for suffix in TITLE_SUFFIXES:
        if title.endswith(suffix):
            title = title[: -len(suffix)].strip()
    return title


def compact_whitespace(value: str) -> str:
    return re.sub(r"\s+", " ", value or "").strip()


def normalize_body(value: str) -> str:
    value = html.unescape(value or "")
    value = value.replace("\r", "\n")
    value = re.sub(r"\n\s*\n\s*\n+", "\n\n", value)
    lines = [compact_whitespace(line) for line in value.splitlines()]
    lines = [line for line in lines if line]
    return "\n".join(lines)


def looks_like_error_page(title: str, body_text: str) -> bool:
    haystack = f"{title}\n{body_text}".lower()
    return any(pattern in haystack for pattern in ERROR_PATTERNS)


def looks_like_non_product_page(title: str, canonical_url: str, body_text: str) -> bool:
    normalized_title = compact_whitespace(title).lower()
    normalized_url = canonical_url.lower()
    normalized_body = body_text.lower()
    product_signal = (
        "/product/" in normalized_url
        or "/products/" in normalized_url
        or "product/" in normalized_url
        or "thermostat" in normalized_title
        or "pump" in normalized_title
        or "burner" in normalized_title
        or "detector" in normalized_title
        or "control" in normalized_title
        or "ignitor" in normalized_title
        or "circulator" in normalized_title
        or "purifier" in normalized_title
    )

    if any(pattern in normalized_title for pattern in BAD_TITLE_PATTERNS) and not product_signal:
        return True

    if any(pattern in normalized_url for pattern in BAD_URL_PATTERNS) and not product_signal:
        return True

    if (
        "skip to content" in normalized_body
        and "support center" in normalized_body
        and not product_signal
    ):
        return True

    if "available documents" in normalized_body and "broken link" in normalized_body:
        return True

    if "location" in normalized_body and "choose a currency" in normalized_body:
        return True

    if not normalized_title and not normalized_url:
        return True

    if normalized_title == "404":
        return True

    if normalized_url in {"", "/in"}:
        return True

    if "cookie preferences" in normalized_body and "sign up for the latest deals" in normalized_body:
        return True

    if "watch on youtube" in normalized_body and not product_signal:
        return True

    return False


def remove_duplicate_lines(body_text: str) -> str:
    lines = body_text.splitlines()
    counter = Counter(lines)
    filtered: list[str] = []

    for line in lines:
        if counter[line] > 8 and len(line) < 80:
            continue
        if filtered and filtered[-1] == line:
            continue
        filtered.append(line)

    return "\n".join(filtered).strip()


def choose_output_name(source_path: Path, title: str, canonical_url: str) -> str:
    if canonical_url:
        path = urlparse(canonical_url).path.rstrip("/")
        if path:
            return f"{path.split('/')[-1]}.md"

    stem = source_path.stem
    stem = re.sub(r"_\d+$", "", stem)
    if title:
        title_slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
        if title_slug:
            stem = title_slug
    return f"{stem}.md"


def render_markdown(source_path: Path, parsed: dict[str, str]) -> str:
    title = parsed["title"] or re.sub(r"_\d+$", "", source_path.stem)
    description = parsed["description"]
    canonical_url = parsed["canonical_url"]
    body_text = remove_duplicate_lines(parsed["body_text"])

    lines = [f"# {title}", ""]
    if description:
        lines.extend(["Description", description, ""])
    if canonical_url:
        lines.extend(["Source URL", canonical_url, ""])
    lines.extend(["Content", body_text, ""])
    return "\n".join(lines).strip() + "\n"


def process_file(source_path: Path, output_dir: Path) -> dict[str, str]:
    raw_html = source_path.read_text(encoding="utf-8", errors="ignore")
    parser = ProductSheetParser()
    parser.feed(raw_html)
    parsed = parser.extract()

    if looks_like_error_page(parsed["title"], parsed["body_text"]):
        return {"status": "skipped", "reason": "error_page", "source": str(source_path)}

    if len(parsed["body_text"]) < 200:
        return {"status": "skipped", "reason": "too_short", "source": str(source_path)}

    if looks_like_non_product_page(
        parsed["title"], parsed["canonical_url"], parsed["body_text"]
    ):
        return {"status": "skipped", "reason": "non_product_page", "source": str(source_path)}

    output_name = choose_output_name(source_path, parsed["title"], parsed["canonical_url"])
    output_path = output_dir / output_name
    output_path.write_text(render_markdown(source_path, parsed), encoding="utf-8")

    return {
        "status": "converted",
        "source": str(source_path),
        "output": str(output_path),
        "title": parsed["title"],
        "canonical_url": parsed["canonical_url"],
    }


def main() -> None:
    arg_parser = argparse.ArgumentParser(
        description="Convert local HTML product sheets into vector-store-friendly markdown files."
    )
    arg_parser.add_argument("source_dir", type=Path)
    arg_parser.add_argument("output_dir", type=Path)
    args = arg_parser.parse_args()

    source_dir = args.source_dir
    output_dir = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    html_files = sorted(source_dir.glob("*.htm")) + sorted(source_dir.glob("*.html"))
    results = [process_file(path, output_dir) for path in html_files]

    summary = {
        "source_dir": str(source_dir),
        "output_dir": str(output_dir),
        "converted": sum(1 for item in results if item["status"] == "converted"),
        "skipped": sum(1 for item in results if item["status"] == "skipped"),
        "results": results,
    }

    summary_path = output_dir / "conversion-summary.json"
    summary_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
