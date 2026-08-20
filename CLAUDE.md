# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Salesforce DX project named **Ascend** targeting API version 66.0. Custom source lives under `force-app/` (the default package directory). The org is a Developer Edition scratch org (`config/project-scratch-def.json`).

## Commands

### Salesforce CLI (sf / sfdx)

```bash
# Authenticate to an org
sf org login web --alias my-org

# Create a scratch org
sf org create scratch --definition-file config/project-scratch-def.json --alias ascend-dev --set-default

# Push local source to scratch org
sf project deploy start

# Pull changes from org back to local
sf project retrieve start

# Open the org in a browser
sf org open

# Run Apex tests in the org
sf apex run test --test-level RunLocalTests --output-dir test-results

# Run a single Apex test class
sf apex run test --class-names MyTestClass

# Deploy specific metadata
sf project deploy start --source-dir force-app/main/default/classes/MyClass.cls

# Execute anonymous Apex
sf apex run --file scripts/apex/hello.apex
```

### JavaScript (LWC)

```bash
npm install          # Install dependencies

npm run lint         # Lint Aura and LWC JS files
npm run test         # Run all LWC Jest unit tests
npm run test:unit:watch    # Run tests in watch mode
npm run test:unit:debug    # Run tests with Node debugger
npm run test:unit:coverage # Run tests with coverage report

# Run Jest tests for a specific LWC component
npx sfdx-lwc-jest -- --testPathPattern=force-app/main/default/lwc/myComponent

npm run prettier        # Format all source files
npm run prettier:verify # Check formatting without writing
```

### Pre-commit hooks

Husky runs `lint-staged` on commit: Prettier formats staged files, ESLint lints Aura/LWC JS, and Jest runs tests related to changed LWC files (`--bail --findRelatedTests`).

## Architecture

### Source layout

All custom metadata lives under `force-app/main/default/` organized by metadata type:
- `classes/` — Apex classes and test classes
- `triggers/` — Apex triggers
- `lwc/` — Lightning Web Components (each component is a folder with `.html`, `.js`, `.js-meta.xml`, optional `.css` and `__tests__/`)
- `aura/` — Aura components (legacy)
- `objects/` — Custom objects, fields, validation rules, etc.
- `flows/` — Flows and process automations

### LWC conventions

- Test files sit in `__tests__/` inside the component folder and are excluded from org deployment via `.forceignore`.
- Jest config extends `@salesforce/sfdx-lwc-jest` defaults; `.localdevserver` is ignored.
- ESLint uses separate rule sets: `@salesforce/eslint-config-lwc/recommended` for LWC, `@salesforce/eslint-plugin-aura` (recommended + locker) for Aura. Wire adapter checks are disabled in test files.

### Prettier

Apex is formatted via `prettier-plugin-apex`, XML via `@prettier/plugin-xml`. LWC HTML uses the `lwc` parser; Visualforce/Aura markup uses `html`. Trailing commas are disabled globally.

### Deployment model

This project uses the **org development model** (push/pull against a scratch org) rather than package development. `manifest/package.xml` targets `ApexClass`, `ApexTrigger`, `AuraDefinitionBundle`, `LightningComponentBundle`, `ApexPage`, `ApexComponent`, `ApexTestSuite`, and `StaticResource`.
