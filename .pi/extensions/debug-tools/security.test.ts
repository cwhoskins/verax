/**
 * Unit tests for the debug-tools security helpers.
 *
 * Run with:
 *   node --experimental-strip-types --test .pi/extensions/debug-tools/security.test.ts
 */

import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
	buildSandboxArgs,
	ensureTmpRootSafe,
	findBwrapOnPath,
	findProjectRoot,
	getTmpRoot,
	validateTmpPath,
} from "./security.ts";

function makeRepo(): string {
	const repo = fs.mkdtempSync(path.join(os.tmpdir(), "nimcir-dbg-sec-"));
	fs.mkdirSync(path.join(repo, ".git"));
	fs.mkdirSync(path.join(repo, ".tmp"));
	return repo;
}

function makeRepoWithoutTmp(): string {
	const repo = fs.mkdtempSync(path.join(os.tmpdir(), "nimcir-dbg-sec-"));
	fs.mkdirSync(path.join(repo, ".git"));
	return repo;
}

test("relative .tmp child is accepted", () => {
	const repo = makeRepo();
	const tmp = getTmpRoot(repo);
	const result = validateTmpPath(repo, ".tmp/probe.nim");
	assert.equal(result.ok, true);
	if (result.ok) assert.equal(result.resolved, path.join(tmp, "probe.nim"));
});

test("absolute .tmp child is accepted", () => {
	const repo = makeRepo();
	const tmp = getTmpRoot(repo);
	const result = validateTmpPath(repo, path.join(tmp, "log.txt"));
	assert.equal(result.ok, true);
	if (result.ok) assert.equal(result.resolved, path.join(tmp, "log.txt"));
});

test("parent traversal is rejected", () => {
	const repo = makeRepo();
	const result = validateTmpPath(repo, ".tmp/../CLAUDE.md");
	assert.equal(result.ok, false);
	if (!result.ok) assert.match(result.reason, /escapes/);
});

test("absolute path outside .tmp is rejected", () => {
	const repo = makeRepo();
	const result = validateTmpPath(repo, path.join(repo, "src", "probe.nim"));
	assert.equal(result.ok, false);
});

test(".tmp-other prefix collision is rejected", () => {
	const repo = makeRepo();
	const result = validateTmpPath(repo, path.join(repo, ".tmp-other", "probe.nim"));
	assert.equal(result.ok, false);
});

test("symlinked target component is rejected", () => {
	const repo = makeRepo();
	const tmp = getTmpRoot(repo);
	const outside = path.join(repo, "outside");
	fs.mkdirSync(outside);
	fs.symlinkSync(outside, path.join(tmp, "link"));

	const result = validateTmpPath(repo, path.join(tmp, "link", "probe.nim"));
	assert.equal(result.ok, false);
	if (!result.ok) assert.match(result.reason, /escapes/);
});

test("symlinked .tmp root is rejected", () => {
	const repo = makeRepoWithoutTmp();
	const real = path.join(repo, "real-tmp");
	fs.mkdirSync(real);
	fs.symlinkSync(real, path.join(repo, ".tmp"));

	assert.throws(() => ensureTmpRootSafe(repo), /symlink/);
	const result = validateTmpPath(repo, path.join(repo, ".tmp", "probe.nim"));
	assert.equal(result.ok, false);
	if (!result.ok) assert.match(result.reason, /symlink/);
});

test("sandbox argument construction keeps the command a single shell argument", () => {
	const repo = makeRepo();
	const tmp = getTmpRoot(repo);
	const command = 'printf "a b" > .tmp/out.txt; echo done; cat < .tmp/out.txt';

	const args = buildSandboxArgs({ repoRoot: repo, tmpRoot: tmp, command, shellPath: "/bin/bash" });

	// The command must be a single trailing argument to the sandbox shell.
	assert.equal(args[args.length - 3], "/bin/bash");
	assert.equal(args[args.length - 2], "-c");
	assert.equal(args[args.length - 1], command);

	// Read-only root mount.
	const ro = args.indexOf("--ro-bind");
	assert.ok(ro !== -1);
	assert.equal(args[ro + 1], "/");
	assert.equal(args[ro + 2], "/");

	// Writable .tmp bind.
	const bind = args.indexOf("--bind");
	assert.ok(bind !== -1);
	assert.equal(args[bind + 1], tmp);
	assert.equal(args[bind + 2], tmp);

	// Private /tmp and network isolation and repository cwd.
	const tmpfs = args.indexOf("--tmpfs");
	assert.ok(tmpfs !== -1);
	assert.equal(args[tmpfs + 1], "/tmp");
	assert.ok(args.includes("--unshare-net"));
	const chdir = args.indexOf("--chdir");
	assert.ok(chdir !== -1);
	assert.equal(args[chdir + 1], repo);
});

test("findProjectRoot walks up to the nearest .git ancestor", () => {
	const repo = makeRepo();
	const nested = path.join(repo, "a", "b", "c");
	fs.mkdirSync(nested, { recursive: true });
	assert.equal(findProjectRoot(nested), repo);
	assert.equal(findProjectRoot(repo), repo);
	assert.equal(findProjectRoot(os.tmpdir()), null);
});

test("findBwrapOnPath returns null when bwrap is absent", () => {
	assert.equal(findBwrapOnPath({ PATH: "/nonexistent" }), null);
});
