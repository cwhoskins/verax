/**
 * Sandbox integration tests for the fail-closed bubblewrap runner.
 *
 * Run with:
 *   command -v bwrap
 *   node --experimental-strip-types --test .pi/extensions/debug-tools/sandbox.test.ts
 */

import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { findBwrapOnPath, getTmpRoot, runSandboxedCommand } from "./security.ts";

const hasBwrap = Boolean(findBwrapOnPath());
const skipWithoutBwrap = hasBwrap ? false : "bwrap (bubblewrap) not available on PATH";

function makeRepo(): string {
	// The sandbox mounts a fresh tmpfs over /tmp, so a repo under os.tmpdir()
	// would be hidden by that mount. Use $HOME, which stays a read-only bind
	// of the host filesystem, so the write-boundary assertions see the real
	// repository tree.
	const repo = fs.mkdtempSync(path.join(os.homedir(), "nimcir-dbg-sandbox-"));
	fs.mkdirSync(path.join(repo, ".git"));
	fs.mkdirSync(path.join(repo, ".tmp"));
	return repo;
}

test("sandbox allows writes under .tmp/", { skip: skipWithoutBwrap }, async () => {
	const repo = makeRepo();
	const tmp = getTmpRoot(repo);
	const result = await runSandboxedCommand({
		repoRoot: repo,
		tmpRoot: tmp,
		command: "printf allowed > .tmp/sandbox-allowed.txt",
	});
	assert.equal(result.exitCode, 0);
	assert.equal(fs.readFileSync(path.join(tmp, "sandbox-allowed.txt"), "utf8"), "allowed");
});

test("sandbox denies writes at the repository root", { skip: skipWithoutBwrap }, async () => {
	const repo = makeRepo();
	const tmp = getTmpRoot(repo);
	const result = await runSandboxedCommand({
		repoRoot: repo,
		tmpRoot: tmp,
		command: "echo denied > sandbox-denied.txt",
	});
	assert.notEqual(result.exitCode, 0);
	assert.equal(fs.existsSync(path.join(repo, "sandbox-denied.txt")), false);
});

test("sandbox denies overwriting files outside .tmp/", { skip: skipWithoutBwrap }, async () => {
	const repo = makeRepo();
	const tmp = getTmpRoot(repo);
	const fixture = path.join(repo, "readonly-fixture.txt");
	fs.writeFileSync(fixture, "original");

	const result = await runSandboxedCommand({
		repoRoot: repo,
		tmpRoot: tmp,
		command: "echo tampered > readonly-fixture.txt",
	});
	assert.notEqual(result.exitCode, 0);
	assert.equal(fs.readFileSync(fixture, "utf8"), "original");
});

test("a script in .tmp/ cannot write outside .tmp/", { skip: skipWithoutBwrap }, async () => {
	const repo = makeRepo();
	const tmp = getTmpRoot(repo);
	fs.writeFileSync(
		path.join(tmp, "escape.sh"),
		"#!/bin/sh\nprintf inside > .tmp/inside.txt\nprintf outside > escaped-root.txt\n",
	);

	const result = await runSandboxedCommand({
		repoRoot: repo,
		tmpRoot: tmp,
		command: "sh .tmp/escape.sh",
	});
	assert.equal(fs.existsSync(path.join(tmp, "inside.txt")), true);
	assert.equal(fs.existsSync(path.join(repo, "escaped-root.txt")), false);
	assert.notEqual(result.exitCode, 0);
});

test("sandbox has no network access", { skip: skipWithoutBwrap }, async () => {
	const repo = makeRepo();
	const tmp = getTmpRoot(repo);
	const command =
		"if timeout 5 bash -c 'echo hi > /dev/tcp/8.8.8.8/53' 2>/dev/null; " +
		"then echo CONNECTED > .tmp/net-ok.txt; else echo BLOCKED > .tmp/net-blocked.txt; fi";

	const result = await runSandboxedCommand({
		repoRoot: repo,
		tmpRoot: tmp,
		command,
		shellPath: "/bin/bash",
	});
	assert.equal(result.exitCode, 0);
	assert.equal(fs.existsSync(path.join(tmp, "net-blocked.txt")), true);
	assert.equal(fs.existsSync(path.join(tmp, "net-ok.txt")), false);
});

test("missing bwrap fails closed and never runs unsandboxed", async () => {
	const repo = makeRepo();
	const tmp = getTmpRoot(repo);

	await assert.rejects(
		runSandboxedCommand({
			repoRoot: repo,
			tmpRoot: tmp,
			command: "echo should-not-run > .tmp/ran.txt",
			env: { PATH: "/nonexistent" },
		}),
		/bwrap/,
	);
	assert.equal(fs.existsSync(path.join(tmp, "ran.txt")), false);
});
