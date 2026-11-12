//! rust-genai, with every model sent to the stand-in as an OpenAI-compatible endpoint.
use futures::StreamExt;
use genai::adapter::AdapterKind;
use genai::chat::{ChatMessage, ChatRequest, ChatStreamEvent};
use genai::resolver::{AuthData, Endpoint, ServiceTargetResolver};
use genai::{Client, ModelIden, ServiceTarget};

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let (base, n, stream) = rust_clients::args();
    let base: &'static str = Box::leak(format!("{}/", base.trim_end_matches('/')).into_boxed_str());
    let key = rust_clients::key();
    let resolver = ServiceTargetResolver::from_resolver_fn(move |target: ServiceTarget| -> Result<ServiceTarget, genai::resolver::Error> {
        Ok(ServiceTarget { endpoint: Endpoint::from_static(base), auth: AuthData::from_single(key.clone()), model: ModelIden::new(AdapterKind::OpenAI, target.model.model_name) })
    });
    let client = Client::builder().with_service_target_resolver(resolver).build().expect("a client");
    let client = &client;
    rust_clients::run(n, |i| async move {
        let request = ChatRequest::new(vec![ChatMessage::user(format!("call {i}"))]);
        if stream {
            let mut text = String::new();
            let mut events = client.exec_chat_stream("mock", request, None).await.expect("a stream").stream;
            while let Some(event) = events.next().await {
                if let Ok(ChatStreamEvent::Chunk(chunk)) = event {
                    text.push_str(&chunk.content);
                }
            }
            text
        } else {
            client.exec_chat("mock", request, None).await.expect("an answer").first_text().unwrap_or_default().to_string()
        }
    })
    .await;
}
