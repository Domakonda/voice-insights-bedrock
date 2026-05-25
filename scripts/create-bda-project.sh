#!/usr/bin/env bash
# Creates a Bedrock Data Automation project configured for audio transcription
# with speaker labeling + audio summary + topic summary.
#
# Usage:
#   AWS_REGION=us-east-1 ./scripts/create-bda-project.sh
#
# Prints the project ARN — paste into terraform/terraform.tfvars.

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
NAME="${BDA_PROJECT_NAME:-voice-insights-audio}"
CFG_FILE="$(mktemp -t voice-insights-bda-cfg-XXXXXX.json)"
trap 'rm -f "$CFG_FILE"' EXIT

cat > "$CFG_FILE" <<'JSON'
{
  "audio": {
    "extraction": {
      "category": {
        "state": "ENABLED",
        "types": ["TRANSCRIPT", "AUDIO_CONTENT_MODERATION"],
        "typeConfiguration": {
          "transcript": {
            "speakerLabeling": { "state": "ENABLED" },
            "channelLabeling": { "state": "ENABLED" }
          }
        }
      }
    },
    "generativeField": {
      "state": "ENABLED",
      "types": ["AUDIO_SUMMARY", "TOPIC_SUMMARY"]
    }
  }
}
JSON

aws bedrock-data-automation create-data-automation-project \
  --region "$REGION" \
  --project-name "$NAME" \
  --project-description "Audio transcription + insights for voice-insights-bedrock" \
  --standard-output-configuration "file://$CFG_FILE" \
  --query 'projectArn' --output text
