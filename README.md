# Multi-Tenant Cortex Agent Native App

A Snowflake Native App that packages a [Cortex Agent](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agent) with [Cortex Analyst](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst) (text-to-SQL) inside a distributable native app. Each consumer gets automatic per-tenant data isolation via row access policies, with a Streamlit chat UI for natural language queries against their data.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  PROVIDER ACCOUNT                                   │
│                                                     │
│  IDEAL_AGENT_POC (Database)                         │
│  ├── DATA.SALES          ← base table + RAP         │
│  ├── DATA.V_SALES        ← secure view (no tenant)  │
│  └── DATA.TENANT_RAP     ← CURRENT_ACCOUNT() filter │
│                                                     │
│  IDEAL_AGENT_APP_PKG (Application Package)          │
│  ├── SHARED_CONTENT.V_SALES  ← proxy view to share  │
│  └── STAGE_SCHEMA.APP_STAGE  ← app files             │
├─────────────────────────────────────────────────────┤
│  CONSUMER ACCOUNT (installed via listing)            │
│                                                     │
│  IDEAL_AGENT_APP (Application)                      │
│  └── CORE                                           │
│      ├── V_SALES              ← reads shared data    │
│      ├── SALES_SEMANTIC_VIEW  ← created at install   │
│      ├── SALES_AGENT          ← created by INITIALIZE│
│      ├── CALL_AGENT()         ← query the agent      │
│      ├── INITIALIZE()         ← one-time setup       │
│      └── CHATBOT              ← Streamlit UI         │
└─────────────────────────────────────────────────────┘
```

**Key design decisions:**

- **Agent created inside the app** — `CREATE AGENT` runs during `INITIALIZE()`, not externally. The agent lives within the app's security boundary.
- **Self-contained semantic view** — The semantic view is created by `setup.sql` inside the app, pointing to the internal view. Consumers don't need to create or manage any external objects.
- **Row access policy on `CURRENT_ACCOUNT()`** — Applied to the base table on the provider side. Each consumer automatically sees only their own rows. The `tenant_id` column is excluded from the shared view.
- **Single-command initialization** — Consumer runs `CALL INITIALIZE('<warehouse>')` and the agent + semantic view + grants are all configured.

## Prerequisites

- Two Snowflake accounts in the same organization (provider + consumer)
- `ACCOUNTADMIN` role on both accounts
- [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index) (`snow`) installed
- `SNOWFLAKE.CORTEX_USER` database role available (Cortex features enabled)

## Quick Start

### 1. Configure

```bash
cp .env.example .env
# Edit .env with your account details:
#   PROVIDER_ACCOUNT   — run SELECT CURRENT_ACCOUNT() on provider
#   CONSUMER_ACCOUNT   — run SELECT CURRENT_ACCOUNT() on consumer
#   WAREHOUSE          — warehouse name (e.g., COMPUTE_WH)
#   SNOW_CONNECTION    — your Snowflake CLI connection name
make render
```

### 2. Provider Setup

```bash
# Create database, sample data, row access policy, semantic view
snow sql -f provider/01_setup.sql -c <your_connection>

# Create application package and stage
snow sql -f scripts/deploy.sql -c <your_connection>

# Upload app files to stage
snow stage copy app-package/manifest.yml @IDEAL_AGENT_APP_PKG.STAGE_SCHEMA.APP_STAGE/ --overwrite -c <your_connection>
snow stage copy app-package/setup.sql @IDEAL_AGENT_APP_PKG.STAGE_SCHEMA.APP_STAGE/ --overwrite -c <your_connection>
snow stage copy app-package/environment.yml @IDEAL_AGENT_APP_PKG.STAGE_SCHEMA.APP_STAGE/ --overwrite -c <your_connection>
snow stage copy app-package/streamlit/chatbot.py @IDEAL_AGENT_APP_PKG.STAGE_SCHEMA.APP_STAGE/streamlit/ --overwrite -c <your_connection>
```

### 3. Dev Mode (Same-Account Test)

```bash
snow sql -f scripts/install.sql -c <your_connection>
```

This drops any existing app, installs from the stage, grants `CORTEX_USER`, and calls `INITIALIZE`.

### 4. Cross-Account Distribution

```bash
# Set up sharing, versioning, and distribution
snow sql -f scripts/share.sql -c <your_connection>
```

Then on the consumer account:

```bash
snow sql -f scripts/consumer_install.sql -c <consumer_connection>
```

## Project Structure

```
mt-cortex-na/
├── .env.example                          # Template for account config
├── Makefile                              # make render / make clean
├── app-package/
│   ├── manifest.yml                      # App manifest
│   ├── setup.sql                         # App setup: views, semantic view, procedures, Streamlit
│   ├── environment.yml                   # Python dependencies
│   └── streamlit/
│       └── chatbot.py                    # Chat UI
├── provider/
│   └── 01_setup.sql.template             # Database, sample data, RAP, semantic view
└── scripts/
    ├── deploy.sql.template               # Create app package + stage
    ├── share.sql.template                # Share data, version, distribute
    ├── install.sql.template              # Dev-mode same-account install
    └── consumer_install.sql.template     # Consumer-side install guide
```

Files ending in `.template` contain `${VAR}` placeholders. Run `make render` to generate the corresponding `.sql` files from your `.env` values.

## How It Works

### Data Flow

1. **Provider** creates a sales table with a `tenant_id` column matching each account's locator
2. A **row access policy** (`CURRENT_ACCOUNT() = tenant_id`) is attached to the base table
3. A **secure view** (`V_SALES`) exposes all columns except `tenant_id`
4. The app package's **proxy view** (`SHARED_CONTENT.V_SALES`) references the secure view via `REFERENCE_USAGE`
5. At install, `setup.sql` creates an **internal view** and **semantic view** inside the app
6. `INITIALIZE()` creates a **Cortex Agent** with a Cortex Analyst tool pointed at the semantic view
7. Consumers query via `CALL_AGENT('question')` or the **Streamlit chat UI**

### Multi-Tenant Isolation

The row access policy ensures each account only sees its own data — enforced at the storage layer, invisible to the app logic. The agent, semantic view, and Streamlit UI all operate on the filtered view without any tenant-awareness in their code.

| Account | Rows | Products | Salespersons |
|---------|------|----------|--------------|
| Provider | 5 | Widget A/B, Service X/Y | Alice, Bob, Carol, Dave |
| Consumer | 5 | Gadget Pro/Lite/Max, Consulting Basic/Premium | Eve, Frank, Grace |

### Consumer Workflow

After installation, the consumer runs three commands:

```sql
-- 1. Install
CREATE APPLICATION IDEAL_AGENT_APP FROM LISTING '<listing_global_name>';

-- 2. Grant Cortex access
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO APPLICATION IDEAL_AGENT_APP;

-- 3. Initialize
CALL IDEAL_AGENT_APP.CORE.INITIALIZE('COMPUTE_WH');
```

Then query:

```sql
CALL IDEAL_AGENT_APP.CORE.CALL_AGENT('What is the total revenue?');
-- Or open the Streamlit chat UI in Snowsight
```
