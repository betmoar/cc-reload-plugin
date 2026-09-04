#!/usr/bin/env node
// Release gate: a v<x.y.z> tag must match plugin.json and the newest
// CHANGELOG.md heading before a GitHub release is cut.
//
// Run by .github/workflows/release.yml on tag push; also runnable locally
// before pushing a tag:
//
//     node scripts/release-gate.mjs v0.2.0 [--root DIR] [--notes-out FILE]
//
// The coupling this enforces (see CHANGELOG.md's header):
//
//     tag v<x.y.z> == plugin.json "version" == newest CHANGELOG heading
//
// (cc-repete has no package.json — unlike cc-proxy, plugin.json is the single
// version source, so the gate has one fewer arm.)
//
// With --notes-out, the tag version's CHANGELOG section is written to FILE for
// use as the GitHub release body — release notes ARE the changelog, never a
// hand-written duplicate.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const TAG_RE = /^v(\d+\.\d+\.\d+)$/;
// Newest-first list of semver headings, e.g. "## [0.2.0] — 2026-08-17".
const CHANGELOG_HEADING_RE = /^## \[(\d+\.\d+\.\d+)\]/gm;

// Return the CHANGELOG body between '## [version]' and the next '## [' heading
// or the trailing '[' link-reference block (whichever comes first).
export function extractSection(changelogText, version) {
	const esc = version.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
	const start = new RegExp(`^## \\[${esc}\\][^\\n]*\\n`, "m").exec(changelogText);
	if (!start) return "";
	const rest = changelogText.slice(start.index + start[0].length);
	// Stop at the next version heading or the link-reference block. The block
	// test must match the reference SHAPE ("[label]: url"), not any line that
	// merely starts with '[' — a body line like "[MEASURED: …] note" would
	// silently truncate the published release notes (2026-08-31 audit F07).
	//
	// F07's fix narrowed the shape to "[label]: " (colon-space) but that still
	// matches an ordinary changelog callout like "[BREAKING]: config format
	// changed" — a body line, not a reference definition — and silently
	// dropped it and everything after it (issue #22). Require the URL shape
	// instead: real link-reference definitions are "[label]: scheme://...".
	// This chooses the cheap failure direction (dropping content is expensive,
	// keeping one extra body line is cheap) over faithfully detecting the
	// trailing reference block. It still cannot distinguish a body line that
	// itself genuinely reads "[label]: https://…" from a real reference
	// definition — that shape is rare enough in changelog prose to accept.
	const stop = /^## \[|^\[[^\]]+\]:\s*\S+:\/\//m.exec(rest);
	return (stop ? rest.slice(0, stop.index) : rest).trim();
}

function readJsonVersion(path) {
	return JSON.parse(readFileSync(path, "utf8")).version;
}

// Return { problems: string[], notes: string }. Empty problems ⇒ tag may ship.
export function gate(root, tag) {
	const problems = [];
	let notes = "";

	const m = TAG_RE.exec(tag);
	if (!m) {
		problems.push(`tag ${JSON.stringify(tag)} is not v<x.y.z> — retag, e.g. v0.2.0`);
		return { problems, notes };
	}
	const ver = m[1];

	let pluginVer = null;
	try {
		pluginVer = readJsonVersion(join(root, ".claude-plugin", "plugin.json"));
	} catch (e) {
		problems.push(`plugin.json unreadable: ${e.message}`);
	}
	if (pluginVer != null && pluginVer !== ver) {
		problems.push(
			`tag ${tag} does not match plugin.json version ${JSON.stringify(pluginVer)} — bump .claude-plugin/plugin.json (or fix the tag)`,
		);
	}

	let text;
	try {
		text = readFileSync(join(root, "CHANGELOG.md"), "utf8");
	} catch {
		problems.push("CHANGELOG.md: missing");
		return { problems, notes };
	}
	const headings = [...text.matchAll(CHANGELOG_HEADING_RE)].map((x) => x[1]);
	const newest = headings.length ? headings[0] : null;
	if (newest !== ver) {
		problems.push(
			`newest CHANGELOG heading is '[${newest}]' but the tag is ${tag} — the '## [${ver}]' entry must be the first '## [' heading in CHANGELOG.md`,
		);
	} else {
		notes = extractSection(text, ver);
		if (!notes) {
			problems.push(
				`CHANGELOG section for [${ver}] is empty — write the release notes there; they become the GitHub release body`,
			);
		}
	}

	return { problems, notes };
}

function main(argv) {
	const args = argv.slice(2);
	let tag = null;
	let root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
	let notesOut = null;

	for (let i = 0; i < args.length; i++) {
		const a = args[i];
		if (a === "--root") root = args[++i];
		else if (a === "--notes-out") notesOut = args[++i];
		else if (!tag) tag = a;
		else {
			process.stderr.write(`unexpected argument: ${a}\n`);
			return 2;
		}
	}
	if (!tag) {
		process.stderr.write("usage: release-gate.mjs v<x.y.z> [--root DIR] [--notes-out FILE]\n");
		return 2;
	}

	const { problems, notes } = gate(root, tag);
	for (const p of problems) process.stderr.write(`FAIL: ${p}\n`);
	if (problems.length) {
		process.stderr.write(`\nrelease gate: ${problems.length} problem(s); not shipping.\n`);
		return 1;
	}
	if (notesOut) writeFileSync(notesOut, `${notes}\n`, "utf8");
	process.stdout.write(
		`release gate OK: ${tag} == plugin.json == newest CHANGELOG heading\n`,
	);
	return 0;
}

// Only run the CLI when invoked directly, not when imported by tests.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
	process.exitCode = main(process.argv);
}
