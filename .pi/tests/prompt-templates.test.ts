/**
 * Static prompt contracts, not runtime agent/sandbox verification.
 * node --experimental-strip-types --test .pi/tests/prompt-templates.test.ts
 */
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";

const root = new URL("../", import.meta.url);
const read = (file: string): string => readFileSync(new URL(file, root), "utf8");
const names = ["explain", "plan", "debug", "verify", "architecture-review"];

// Deliberately parse only the simple scalar metadata convention used here.
// Reject unsupported/duplicate fields instead of silently accepting arbitrary YAML.
function markdown(file: string) {
	const text = read(file);
	const match = /^---\n([\s\S]*?)\n---\n([\s\S]+)$/.exec(text);
	assert.ok(match, `${file}: frontmatter and body required`);
	const fields = new Map<string, string>();
	for (const line of match[1].split("\n")) {
		const field = /^([a-z-]+):\s*(\S.*)$/.exec(line);
		assert.ok(field, `${file}: scalar metadata required`);
		assert.ok(!fields.has(field[1]), `${file}: duplicate ${field[1]}`);
		fields.set(field[1], field[2]);
	}
	return { fields, body: match[2] };
}

for (const name of [...names, "pipeline"]) {
	test(`${name}: discoverable template with supported metadata and project scope`, () => {
		assert.ok(readdirSync(new URL("prompts/", root)).includes(`${name}.md`));
		const { fields, body } = markdown(`prompts/${name}.md`);
		assert.deepEqual([...fields.keys()].sort(), ["argument-hint", "description"]);
		assert.match(fields.get("argument-hint")!, /<[^>]+>/);
		assert.equal(body.match(/\$ARGUMENTS/g)?.length, 1);
		assert.match(body, /subagent tool/);
		assert.match(body, /agentScope "project"/);
		assert.doesNotMatch(body, /agentScope[\s:"]+(?:user|both)\b/);
		if (name !== "pipeline") {
			assert.match(body, /If no arguments were supplied, ask .* and stop/);
		}
	});
}

test("explain delegates only to reader and forbids planning and execution", () => {
	const { body } = markdown("prompts/explain.md");
	assert.match(body, /delegate only to reader/);
	assert.match(body, /read-only: do not execute code, propose edits, create an implementation plan/);
	assert.match(body, /file paths and symbols/);
	assert.match(body, /Distinguish evidence from inference/);
});

test("plan requires actionable tests and an explicit approval stop", () => {
	const { body } = markdown("prompts/plan.md");
	assert.match(body, /invoke planner/);
	assert.match(body, /test file locations, setup, action, expected result/);
	assert.match(body, /exact targeted and full-suite commands/);
	assert.match(body, /stop for explicit approval before implementation/);
	assert.match(body, /Do not invoke implementer or start verification/);
});

for (const file of ["prompts/debug.md", "prompts/pipeline.md", "agents/orchestrator.md"]) {
	test(`${file}: debug review is a separate, uncontaminated handoff`, () => {
		const { body } = markdown(file);
		assert.match(body, /debugger/);
		assert.match(body, /debug-reviewer[\s\S]*separate task containing only the original question and exact `\.tmp\/` artifact paths/);
		assert.match(body, /Never include a previous transcript, `\{previous\}` substitution, (?:or )?debugger explanations/);
		assert.match(body, /Do not chain debugger output into the review/);
		assert.match(body, /If exact paths are missing, request them before review/);
	});
}

test("debug preserves sandbox and approval boundaries", () => {
	const { body } = markdown("prompts/debug.md");
	assert.match(body, /debug_write and debug_bash/);
	assert.match(body, /Never fall back to unsandboxed execution/);
	assert.match(body, /agreements, disagreements, uncertainty/);
	assert.match(body, /Do not edit production code/);
	assert.match(body, /planner, explicit user approval, implementer, and test-runner/);
});

test("verify reports output, incomplete runs, and skips without automatic fixes", () => {
	const { body } = markdown("prompts/verify.md");
	assert.match(body, /delegate verification to test-runner/);
	assert.match(body, /do not assume a full suite/);
	assert.match(body, /complete output, never merely the exit code/);
	assert.match(body, /FAILED or Error:/);
	assert.match(body, /incomplete\/aborted runs/);
	assert.match(body, /missing-toolchain skips/);
	assert.match(body, /found-but-unloadable MFEM install is a failure, not a skip/);
	assert.match(body, /Do not edit files, install software, invoke implementer, or make automatic fixes/);
});

test("architecture reviewer is unpinned and has only read-only tools", () => {
	const { fields, body } = markdown("agents/architecture-reviewer.md");
	assert.deepEqual([...fields.keys()].sort(), ["description", "name", "tools"]);
	assert.equal(fields.get("name"), "architecture-reviewer");
	assert.deepEqual(fields.get("tools")!.split(/,\s*/), ["read", "grep", "find", "ls"]);
	assert.match(body, /Never execute commands, modify files, or implement/);
	for (const evidence of [/CLAUDE\.md/, /docs\/architecture\.md/, /actual imports/, /Ownership/, /coupling/, /Opt-in imports/, /Standard-library-only/, /Nim 2\.2\.10/, /Prioritized recommendations/, /Uncertainty/, /file paths and symbols/]) {
		assert.match(body, evidence);
	}
	assert.match(body, /no supported issue was found/);
	assert.match(body, /Do not claim compilation or runtime validation/);
});

test("architecture template requests evidence, uncertainty, and no model switching", () => {
	const { body } = markdown("prompts/architecture-review.md");
	assert.match(body, /delegate to architecture-reviewer/);
	assert.match(body, /actual imports, types, APIs, callers, and tests/);
	assert.match(body, /prioritized recommendations with tradeoffs/);
	assert.match(body, /explicit uncertainty/);
	assert.match(body, /Remain read-only: no commands, edits, implementation, or automatic fixes/);
	assert.match(body, /Do not switch models automatically/);
	assert.match(body, /inherits the session model only through the active subagent extension's support/);
});

test("README and orchestrator cover every command and conditional model inheritance", () => {
	const docs = [read("README.md"), markdown("agents/orchestrator.md").body];
	for (const text of docs) {
		for (const name of names) assert.ok(text.includes(`/${name}`), name);
		assert.match(text, /agentScope "project"/);
		assert.match(text, /\/model/);
		assert.match(text, /inheritance[\s\S]*extension/);
	}
	assert.match(docs[0], /node --experimental-strip-types --test \.pi\/tests\/prompt-templates\.test\.ts/);
	assert.match(docs[0], /do not execute agents/);
	assert.match(docs[1], /Never automatically switch models/);
});
