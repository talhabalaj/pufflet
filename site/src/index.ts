import { WorkerEntrypoint } from "cloudflare:workers";
const archive = /^Pufflet-\d+(?:\.\d+){0,2}-\d+(?:\.\d+){0,2}\.zip(?:\.sha256)?$/;
export default class extends WorkerEntrypoint<Env> {
  async fetch(request: Request): Promise<Response> {
    if (!["GET", "HEAD"].includes(request.method)) return new Response("Method not allowed", {status:405, headers:{Allow:"GET, HEAD"}});
    const url = new URL(request.url), path = url.pathname;
    if (path === "/downloads/latest.zip") {
      const current = await this.env.RELEASES.get("downloads/manifest.json");
      if (!current) return new Response("The first release is being prepared.", {status:404, headers:{"Cache-Control":"no-store"}});
      const manifest = await current.json<{file:string;notarized:boolean}>();
      if (!archive.test(manifest.file) || !manifest.notarized) return new Response("Release unavailable",{status:503});
      return new Response(null,{status:302,headers:{Location:`/downloads/${manifest.file}`,"Cache-Control":"no-store"}});
    }
    let key: string | undefined;
    if (path === "/appcast.xml" || path === "/downloads/manifest.json") key=path.slice(1);
    else if (path.startsWith("/downloads/") && archive.test(path.slice(11))) key=path.slice(1);
    if (key) {
      const object = await this.env.RELEASES.get(key, {range:request.headers, onlyIf:request.headers});
      if (!object) return new Response("Not found",{status:404,headers:{"Cache-Control":"no-store"}});
      const headers = new Headers({"X-Content-Type-Options":"nosniff"});
      object.writeHttpMetadata(headers); headers.set("ETag",object.httpEtag);
      if (key.endsWith(".xml") || key.endsWith(".json")) headers.set("Cache-Control","no-store");
      if (!("body" in object)) return new Response(null,{status:304,headers});
      if (object.range) {
        const offset = ("offset" in object.range ? object.range.offset : undefined) ?? Math.max(0, object.size - (("suffix" in object.range ? object.range.suffix : undefined) ?? object.size));
        const length = ("length" in object.range ? object.range.length : undefined) ?? object.size-offset;
        headers.set("Content-Range",`bytes ${offset}-${offset+length-1}/${object.size}`);
        headers.set("Content-Length",String(length));
      } else headers.set("Content-Length",String(object.size));
      return new Response(request.method === "HEAD" ? null : object.body,{status:object.range?206:200,headers});
    }
    const response = await this.env.ASSETS.fetch(request);
    const headers = new Headers(response.headers);
    headers.set("X-Content-Type-Options","nosniff"); headers.set("Referrer-Policy","strict-origin-when-cross-origin");
    return new Response(response.body,{status:response.status,headers});
  }
}
