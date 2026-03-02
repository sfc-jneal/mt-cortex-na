"""Sales Analytics Assistant — Streamlit Chat UI.

Calls the in-app CORE.CALL_AGENT() procedure directly via Snowpark session.
No external access, JWT, or auth needed — agent lives inside the native app.
"""
import streamlit as st
import json
from snowflake.snowpark.context import get_active_session

session = get_active_session()

st.set_page_config(page_title="Sales Agent", page_icon=":bar_chart:", layout="wide")
st.title("Sales Analytics Assistant")
st.caption("Powered by Snowflake Cortex Agent")

# -- Sidebar --
with st.sidebar:
    st.header("Sales Agent")

    if st.button("New Conversation", use_container_width=True):
        st.session_state.messages = []
        st.rerun()

    st.divider()
    st.markdown("**Sample questions:**")
    st.markdown(
        "- Show me total revenue across all products\n"
        "- Which salesperson has the highest revenue?\n"
        "- What is the revenue for each product category?\n"
        "- Show me sales by region"
    )

# -- Chat history --
if "messages" not in st.session_state:
    st.session_state.messages = []

for msg in st.session_state.messages:
    with st.chat_message(msg["role"]):
        st.markdown(msg["content"])

# -- Chat input --
if prompt := st.chat_input("Ask about sales data..."):
    st.session_state.messages.append({"role": "user", "content": prompt})
    with st.chat_message("user"):
        st.markdown(prompt)

    with st.chat_message("assistant"):
        with st.spinner("Analyzing..."):
            try:
                safe_prompt = prompt.replace("'", "''")
                result = session.sql(f"CALL CORE.CALL_AGENT('{safe_prompt}')").collect()
                raw = result[0][0] if result else "{}"
                parsed = json.loads(raw) if isinstance(raw, str) else raw

                if parsed.get("status") == "success":
                    response = parsed.get("response", "No response text.")
                else:
                    response = f"Error: {parsed.get('content', parsed.get('code', 'Unknown error'))}"
            except Exception as e:
                response = f"Error: {e}"

        st.markdown(response)

    st.session_state.messages.append({"role": "assistant", "content": response})
