//! graniet's llm, with its OpenAI backend pointed at the stand-in.
use futures::StreamExt;
use llm::builder::{LLMBackend, LLMBuilder};
use llm::chat::ChatMessage;

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let (base, n, stream) = rust_clients::args();
    let client = LLMBuilder::new().backend(LLMBackend::OpenAI).api_key(rust_clients::key()).base_url(format!("{}/", base.trim_end_matches('/'))).model("mock").build().expect("a client");
    let client = &client;
    rust_clients::run(n, |i| async move {
        let messages = vec![ChatMessage::user().content(format!("call {i}")).build()];
        if stream {
            let mut text = String::new();
            let mut pieces = client.chat_stream(&messages).await.expect("a stream");
            while let Some(piece) = pieces.next().await {
                if let Ok(p) = piece {
                    text.push_str(&p);
                }
            }
            text
        } else {
            client.chat(&messages).await.expect("an answer").text().unwrap_or_default()
        }
    })
    .await;
}
