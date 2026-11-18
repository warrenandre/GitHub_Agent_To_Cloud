import assert from "node:assert/strict";
import { WithMcp, CallTool, ValidateSettings, settings } from "./mcp-client.mjs";

const args = process.argv.slice(2);
if (args.length > 1 || args.some((arg) => arg !== "--write")) {
  throw new Error("Usage: npm run smoke [-- --write]");
}
ValidateSettings();

await WithMcp(async (client) => {
  const project = settings.project;
  const type = await CallTool(client, "wit_work_item", { action: "get_type", project, workItemType: "Issue" });
  assert.equal(type.name, "Issue", "The target project must support the Basic Issue type.");
  await CallTool(client, "wit_query", {
    action: "wiql",
    project,
    wiql: "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project ORDER BY [System.Id] DESC",
    top: 1,
  });
  console.log(`Read-only MCP access verified for ${settings.organization}/${project}.`);
  if (!args.includes("--write")) return;

  const marker = `Copilot OIDC MCP smoke test ${new Date().toISOString()}`;
  const created = await CallTool(client, "wit_work_item_write", {
    action: "create",
    project,
    workItemType: "Issue",
    fields: [
      { name: "System.Title", value: marker },
      { name: "System.AreaPath", value: project },
      { name: "System.Description", value: "Created by the opt-in OIDC/MCP integration test.", format: "Html" },
    ],
  });
  assert.ok(Number.isSafeInteger(created.id) && created.id > 0, "Create did not return a work item ID.");
  const id = created.id;
  console.log(`Created sample item: https://dev.azure.com/${settings.organization}/${project}/_workitems/edit/${id}`);
  await CallTool(client, "wit_work_item_write", {
    action: "update",
    project,
    id,
    updates: [
      { op: "test", path: "/rev", value: created.rev },
      { op: "add", path: "/fields/System.Description", value: "OIDC/MCP create and update verified." },
    ],
  });
  const commentText = `OIDC/MCP comment verification: ${marker}`;
  const comment = await CallTool(client, "wit_work_item_comment_write", {
    action: "add", project, workItemId: id, text: commentText, format: "Markdown",
  });
  assert.equal(comment.text, commentText, "Comment was not persisted.");
  const url = `https://github.com/${settings.githubRepository}`;
  await CallTool(client, "wit_work_item_link_write", {
    action: "link", project, updates: [{ id, type: "hyperlink", url, comment: "GitHub sample repository" }],
  });
  const saved = await CallTool(client, "wit_work_item", { action: "get", project, id, expand: "All" });
  assert.equal(saved.fields["System.Title"], marker);
  assert.equal(saved.fields["System.TeamProject"], project);
  assert.equal(saved.fields["System.Description"], "OIDC/MCP create and update verified.");
  assert.ok(saved.relations?.some((relation) => relation.rel === "Hyperlink" && relation.url === url));
  console.log(`Verified create, read, revision-checked update, comment, and hyperlink for item ${id}.`);
});
