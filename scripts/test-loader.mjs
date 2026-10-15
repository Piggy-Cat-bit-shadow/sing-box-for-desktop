/**
 * Entry point for `node --import ./scripts/test-loader.mjs`.
 *
 * `node --import` runs its target *before* the test runner loads anything, which is the only
 * point at which resolve hooks can be installed. Installing them after the modules under test
 * had been linked would be too late to help them.
 *
 * `module.registerHooks` rather than `module.register`: the latter is deprecated in Node 26
 * and prints DEP0205 on every run, and a test suite that emits a warning people learn to
 * ignore is a suite whose real warnings get ignored too. The hooks API is synchronous, which
 * is why the resolver exports `resolveSync`.
 */
import { registerHooks } from "node:module";

import { resolveSync } from "./resolve-typescript.mjs";

registerHooks({ resolve: resolveSync });
