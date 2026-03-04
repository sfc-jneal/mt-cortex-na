# Render .sql files from .template files using values in .env
# Usage:
#   cp .env.example .env   # one-time
#   vim .env               # fill in your values
#   make render             # generate .sql files

TEMPLATES := $(shell find . -name '*.template' -not -path './.git/*')
RENDERED  := $(TEMPLATES:.template=)

.PHONY: render clean

render: .env $(TEMPLATES)
	@set -a && . ./.env && set +a && \
	for tmpl in $(TEMPLATES); do \
		out=$${tmpl%.template}; \
		cp "$$tmpl" "$$out"; \
		sed -i '' \
			-e "s|\$${PROVIDER_ACCOUNT}|$$PROVIDER_ACCOUNT|g" \
			-e "s|\$${CONSUMER_ACCOUNT}|$$CONSUMER_ACCOUNT|g" \
			-e "s|\$${WAREHOUSE}|$$WAREHOUSE|g" \
      -e "s|\$${SNOW_CONNECTION}|$$SNOW_CONNECTION|g" \
      -e "s|\$${APP_NAME}|$$APP_NAME|g" \
			"$$out"; \
		echo "  rendered $$out"; \
	done
	@echo "Done. $(words $(TEMPLATES)) file(s) rendered."

clean:
	@for tmpl in $(TEMPLATES); do \
		out=$${tmpl%.template}; \
		rm -f "$$out"; \
	done
	@echo "Cleaned rendered files."
