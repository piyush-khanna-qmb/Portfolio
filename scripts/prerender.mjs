// Runs after `vite build`. Crawls every URL listed in public/sitemap.xml
// against the freshly built dist/ (served locally with SPA fallback),
// captures what a real browser actually renders for each route — title,
// meta tags set by <Helmet>, and all body content — and writes it to
// dist/<route>/index.html. GitHub Pages serves that file automatically
// when a path like /project/omni is requested, so crawlers that don't
// execute JS (and users on slow connections) get real content on first
// response instead of the empty CSR shell.
//
// See public/404.html for the fallback that still handles any URL NOT
// in this list.

import { readFileSync, mkdirSync, writeFileSync, existsSync } from "node:fs";
import { createServer } from "node:http";
import { join, dirname, extname } from "node:path";
import { fileURLToPath } from "node:url";
import puppeteer from "puppeteer";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..");
const DIST = join(ROOT, "dist");
const SITE_URL = "https://piyushkhanna.space";
const PORT = 45678;

const MIME = {
  ".html": "text/html",
  ".js": "application/javascript",
  ".css": "text/css",
  ".json": "application/json",
  ".xml": "application/xml",
  ".txt": "text/plain",
  ".webmanifest": "application/manifest+json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".ico": "image/x-icon",
  ".mp4": "video/mp4",
  ".pdf": "application/pdf",
  ".gltf": "model/gltf+json",
  ".bin": "application/octet-stream",
};

function getRoutesFromSitemap() {
  const xml = readFileSync(join(ROOT, "public", "sitemap.xml"), "utf-8");
  const matches = [...xml.matchAll(/<loc>(.*?)<\/loc>/g)];
  return matches.map((m) => m[1].replace(SITE_URL, "") || "/");
}

function startServer() {
  const server = createServer((req, res) => {
    const urlPath = req.url.split("?")[0];
    const candidate = urlPath === "/" ? "/index.html" : urlPath;
    const filePath = join(DIST, candidate);

    const resolved = existsSync(filePath) ? filePath : join(DIST, "index.html");
    const ext = extname(resolved);

    res.setHeader("Content-Type", MIME[ext] || "application/octet-stream");
    res.end(readFileSync(resolved));
  });

  return new Promise((resolve) => {
    server.listen(PORT, () => resolve(server));
  });
}

async function prerender() {
  const routes = getRoutesFromSitemap();
  const server = await startServer();
  const browser = await puppeteer.launch({
    headless: true,
    args: ["--no-sandbox", "--disable-setuid-sandbox"],
  });

  const captured = [];

  try {
    for (const route of routes) {
      const page = await browser.newPage();
      await page.goto(`http://localhost:${PORT}${route}`, {
        waitUntil: "networkidle0",
      });
      await page.waitForFunction(
        () => document.body.getAttribute("data-prerender-ready") === "true",
        { timeout: 10000 }
      );
      const html = await page.content();
      captured.push({ route, html });
      await page.close();
      console.log(`prerendered ${route}`);
    }
  } finally {
    await browser.close();
    server.close();
  }

  for (const { route, html } of captured) {
    const outDir = route === "/" ? DIST : join(DIST, route);
    mkdirSync(outDir, { recursive: true });
    writeFileSync(join(outDir, "index.html"), html);
  }

  console.log(`\nPrerendered ${captured.length} routes into dist/`);
}

prerender();
