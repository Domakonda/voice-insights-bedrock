resource "aws_apigatewayv2_api" "this" {
  name          = "${local.name_base}-api"
  protocol_type = "HTTP"
  description   = "Voice Insights transcript retrieval API"
}

resource "aws_apigatewayv2_integration" "retrieval" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.retrieval.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "get_transcript" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET /transcripts/{jobId}"
  target    = "integrations/${aws_apigatewayv2_integration.retrieval.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.retrieval.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
