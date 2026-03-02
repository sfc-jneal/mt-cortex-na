-- ============================================================
-- IDEAL ARCHITECTURE POC — Native App Setup Script
-- Phase 5: Cross-Account Distribution
--
-- The app is self-contained: shared data arrives via
-- SHARED_CONTENT.V_SALES (proxy view in app package).
-- Setup creates a semantic view inside the app over that data.
-- Consumer workflow:
--   1. Install app from listing
--   2. GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO APPLICATION <app>
--   3. CALL <app>.CORE.INITIALIZE('<warehouse_name>')
-- ============================================================

CREATE APPLICATION ROLE IF NOT EXISTS APP_PUBLIC;
CREATE APPLICATION ROLE IF NOT EXISTS APP_ADMIN;

-- Non-versioned schema (persists across upgrades)
CREATE SCHEMA IF NOT EXISTS CORE;
GRANT USAGE ON SCHEMA CORE TO APPLICATION ROLE APP_PUBLIC;
GRANT USAGE ON SCHEMA CORE TO APPLICATION ROLE APP_ADMIN;

-- ============================================================
-- INTERNAL VIEW: Reads from shared content provided by app package
-- SHARED_CONTENT.V_SALES is a proxy view created in the app
-- package that references the provider's secure view (with RAP).
-- ============================================================
CREATE OR REPLACE VIEW CORE.V_SALES AS
SELECT * FROM SHARED_CONTENT.V_SALES;

GRANT SELECT ON VIEW CORE.V_SALES TO APPLICATION ROLE APP_PUBLIC;

-- ============================================================
-- SEMANTIC VIEW: Created inside the app at install time.
-- Points to the internal view above. Cortex Analyst queries
-- this to answer user questions via the agent.
-- ============================================================
CREATE OR REPLACE SEMANTIC VIEW CORE.SALES_SEMANTIC_VIEW
  TABLES (
    sales AS CORE.V_SALES
      PRIMARY KEY (sale_id)
      COMMENT = 'Sales transactions with product, region, and salesperson details'
  )
  DIMENSIONS (
    sales.sale_id AS sale_id
      COMMENT = 'Unique identifier for the sale',
    sales.sale_date AS sale_date
      COMMENT = 'Date when the sale occurred',
    sales.product_name AS product_name
      COMMENT = 'Name of the product sold',
    sales.category AS category
      COMMENT = 'Product category',
    sales.region AS region
      COMMENT = 'Sales region',
    sales.salesperson AS salesperson
      COMMENT = 'Name of the salesperson'
  )
  METRICS (
    sales.total_quantity AS SUM(quantity)
      COMMENT = 'Total quantity of items sold',
    sales.total_revenue AS SUM(total_amount)
      COMMENT = 'Total sales revenue in dollars',
    sales.avg_price AS AVG(unit_price)
      COMMENT = 'Average price per unit in dollars',
    sales.num_sales AS COUNT(sale_id)
      COMMENT = 'Number of sales transactions'
  );

GRANT SELECT ON SEMANTIC VIEW CORE.SALES_SEMANTIC_VIEW TO APPLICATION ROLE APP_PUBLIC;

-- ============================================================
-- INITIALIZE: Creates agent post-install
-- Consumer calls this after granting CORTEX_USER to the app.
-- Only needs the warehouse name — semantic view is internal.
-- ============================================================
CREATE OR REPLACE PROCEDURE CORE.INITIALIZE(warehouse_name STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS $$
import json

def run(session, warehouse_name: str) -> str:
    app_db = session.sql("SELECT CURRENT_DATABASE()").collect()[0][0]
    semantic_view = f"{app_db}.CORE.SALES_SEMANTIC_VIEW"

    agent_spec = json.dumps({
      "instructions": {
        "response": "Always include the actual numbers from query results in your response. Be concise and direct.",
        "system": "You are a sales data analyst. Answer questions using the sales_analyst tool. Always report the exact figures returned by queries.",
        "orchestration": "If the sales_analyst tool returns 0 rows or empty results, rephrase your query and try again. For example, instead of asking for 'total revenue' try asking for 'revenue grouped by product_name' or include a dimension like sale_date, region, or category in the query. Do not tell the user the query returned no results until you have retried at least once with a rephrased question that includes a GROUP BY dimension."
      },
      "tools": [
        {
          "tool_spec": {
            "type": "cortex_analyst_text_to_sql",
            "name": "sales_analyst",
            "description": "Query sales data to answer questions about products, revenue, regions, and salesperson performance."
          }
        }
      ],
      "tool_resources": {
        "sales_analyst": {
          "semantic_view": semantic_view,
          "execution_environment": {
            "type": "warehouse",
            "warehouse": warehouse_name
          }
        }
      }
    })

    create_agent_sql = "CREATE OR REPLACE AGENT CORE.SALES_AGENT FROM SPECIFICATION '" + agent_spec.replace("'", "''") + "'"
    session.sql(create_agent_sql).collect()
    session.sql("GRANT USAGE ON AGENT CORE.SALES_AGENT TO APPLICATION ROLE APP_PUBLIC").collect()

    return f"Initialized: agent using {semantic_view}, warehouse {warehouse_name}"
$$;

GRANT USAGE ON PROCEDURE CORE.INITIALIZE(STRING) TO APPLICATION ROLE APP_PUBLIC;

-- ============================================================
-- OR PROCEDURE: Call agent via internal Snow API
-- Pattern from func spec appendix
-- ============================================================
CREATE OR REPLACE PROCEDURE CORE.CALL_AGENT(prompt STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS $$
import _snowflake
import json

def run(session, prompt: str) -> str:
    app_db = session.sql("SELECT CURRENT_DATABASE()").collect()[0][0]

    agent_path = f"/api/v2/databases/{app_db}/schemas/CORE/agents/SALES_AGENT:run"

    payload = {
        "messages": [
            {
                "role": "user",
                "content": [{"type": "text", "text": prompt}]
            }
        ]
    }

    resp = _snowflake.send_snow_api_request(
        "POST",
        agent_path,
        {},
        {},
        payload,
        None,
        120000
    )

    status = resp.get("status", 0)
    content = resp.get("content", "")

    if status == 200:
        # Response is a JSON array of event objects
        try:
            events = json.loads(content)
            # Look for the final "response" event with complete text
            for event in events:
                if event.get("event") == "response":
                    data = event.get("data", {})
                    content_list = data.get("content", [])
                    # Concatenate ALL "text" type content items (agent may produce multiple text blocks around charts)
                    text_parts = [item.get("text", "") for item in content_list if item.get("type") == "text"]
                    if text_parts:
                        return json.dumps({"status": "success", "response": "\n".join(text_parts)})
                    # Fallback: try first item
                    if content_list:
                        return json.dumps({"status": "success", "response": content_list[0].get("text", "")})
            # Fallback: concatenate text deltas
            text_parts = []
            for event in events:
                if event.get("event") == "response.text.delta":
                    text_parts.append(event.get("data", {}).get("text", ""))
            return json.dumps({"status": "success", "response": "".join(text_parts)})
        except json.JSONDecodeError:
            return json.dumps({"status": "error", "code": "parse_error", "content": content[:500]})
    else:
        return json.dumps({"status": "error", "code": status, "content": content})
$$;

GRANT USAGE ON PROCEDURE CORE.CALL_AGENT(STRING) TO APPLICATION ROLE APP_PUBLIC;

-- ============================================================
-- DEBUG PROCEDURE: Returns raw API response for inspection
-- ============================================================
CREATE OR REPLACE PROCEDURE CORE.DEBUG_AGENT(prompt STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS $$
import _snowflake
import json

def run(session, prompt: str) -> str:
    app_db = session.sql("SELECT CURRENT_DATABASE()").collect()[0][0]
    agent_path = f"/api/v2/databases/{app_db}/schemas/CORE/agents/SALES_AGENT:run"
    payload = {
        "messages": [
            {"role": "user", "content": [{"type": "text", "text": prompt}]}
        ]
    }
    resp = _snowflake.send_snow_api_request(
        "POST", agent_path, {}, {}, payload, None, 120000
    )
    content = resp.get("content", "")
    try:
        events = json.loads(content)
        event_types = [e.get("event") for e in events]
        # Show last 5 events in detail
        last_events = events[-5:] if len(events) > 5 else events
        return json.dumps({
            "status": resp.get("status"),
            "num_events": len(events),
            "event_types": event_types,
            "last_events": last_events
        }, default=str)
    except:
        return json.dumps({
            "status": resp.get("status"),
            "content_tail": content[-3000:] if len(content) > 3000 else content
        })
$$;

GRANT USAGE ON PROCEDURE CORE.DEBUG_AGENT(STRING) TO APPLICATION ROLE APP_PUBLIC;

-- ============================================================
-- TEST PROCEDURE (quick validation — calls INITIALIZE first)
-- ============================================================
CREATE OR REPLACE PROCEDURE CORE.TEST_AGENT()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS $$
DECLARE
    result STRING;
BEGIN
    CALL CORE.CALL_AGENT('Say hello and confirm you are working. Keep it to one sentence.');
    result := (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
    RETURN result;
END;
$$;

GRANT USAGE ON PROCEDURE CORE.TEST_AGENT() TO APPLICATION ROLE APP_PUBLIC;

-- ============================================================
-- STREAMLIT: Chat UI (Phase 4)
-- ============================================================
CREATE OR REPLACE STREAMLIT CORE.CHATBOT
    FROM '/streamlit'
    MAIN_FILE = 'chatbot.py';

GRANT USAGE ON STREAMLIT CORE.CHATBOT TO APPLICATION ROLE APP_PUBLIC;
GRANT USAGE ON STREAMLIT CORE.CHATBOT TO APPLICATION ROLE APP_ADMIN;
