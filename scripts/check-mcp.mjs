import assert from "node:assert/strict";
import { WithMcp, configuration } from "./mcp-client.mjs";

await WithMcp(async (client) => {
  const tools = [];
  let cursor;
  do {
    const page = await client.listTools(cursor ? { cursor } : {});
    tools.push(...page.tools);
    cursor = page.nextCursor;
  } while (cursor);
  for (const name of configuration.mcpServers.ado.tools) {
    assert.ok(tools.some((tool) => tool.name === name), `Pinned MCP server is missing ${name}`);
  }
  console.log(`Verified ${configuration.mcpServers.ado.tools.length} allowlisted tools in the pinned MCP server.`);
});
