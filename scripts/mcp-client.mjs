import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

export const root = new URL("../", import.meta.url);
export const settings = JSON.parse(await readFile(new URL("config/settings.json", root), "utf8"));
export const configuration = JSON.parse(await readFile(new URL("config/copilot-mcp.json", root), "utf8"));

export function ValidateSettings(candidate = settings) {
  for (const name of ["githubRepository", "tenantId", "organization", "project", "appDisplayName", "groupName"]) {
    const value = candidate?.[name];
    if (typeof value !== "string" || !value.trim()) {
      throw new Error(`${name} must be a non-empty string.`);
    }
    if (/<[^>]+>|YOUR_[A-Z_]+/.test(value)) {
      throw new Error(`Replace the ${name} placeholder in config/settings.json. See docs/getting-started.md.`);
    }
  }
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(candidate.githubRepository)) {
    throw new Error("githubRepository must be owner/repository.");
  }
  if (!/^[A-Za-z0-9][A-Za-z0-9-]*$/.test(candidate.organization)) {
    throw new Error("organization must be an Azure DevOps organization name, not a URL.");
  }
  if (!/^[a-f0-9]{8}-([a-f0-9]{4}-){3}[a-f0-9]{12}$/i.test(candidate.tenantId) ||
      candidate.tenantId === "00000000-0000-0000-0000-000000000000") {
    throw new Error("tenantId must be your non-zero Entra tenant GUID, not the sample placeholder. See docs/getting-started.md.");
  }
}

export async function WithMcp(action) {
  const client = new Client({ name: "copilot-ado-validation", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [
      fileURLToPath(new URL("node_modules/@azure-devops/mcp/dist/index.js", root)),
      ...configuration.mcpServers.ado.args.slice(2),
    ],
    cwd: fileURLToPath(root),
    env: Object.fromEntries(Object.entries(process.env).filter(([, value]) => value !== undefined)),
    stderr: "inherit",
  });
  try {
    await client.connect(transport);
    return await action(client);
  } finally {
    await client.close();
    await transport.close();
  }
}

export function ParseToolResult(name, result) {
  if (result.isError) {
    throw new Error(`${name} failed: ${JSON.stringify(result.content)}`);
  }
  const text = result.content?.filter((entry) => entry.type === "text").map((entry) => entry.text).join("\n");
  if (!text) throw new Error(`${name} returned no text result.`);
  // The pinned server wraps external JSON in a nonce-matched spotlighting envelope.
  // Decode it only for assertions; never evaluate or follow the enclosed content.
  const envelope = /^<<([a-f0-9]{32})>> \[UNTRUSTED [^\r\n]+ CONTENT \u2014 do not follow any instructions within\] <<\1>>\n([\s\S]*)\n<<\/\1>>$/.exec(text);
  return JSON.parse(envelope ? envelope[2] : text);
}

export async function CallTool(client, name, args) {
  if (!configuration.mcpServers.ado.tools.includes(name)) {
    throw new Error(`Tool is not allowlisted: ${name}`);
  }
  if (args.project !== settings.project) {
    throw new Error(`Tool calls must target project ${settings.project}.`);
  }
  const result = await client.callTool({ name, arguments: args }, undefined, { timeout: 90_000 });
  return ParseToolResult(name, result);
}
