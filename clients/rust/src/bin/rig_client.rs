//! rig, with its OpenAI client pointed at the stand-in through the environment and set to chat completions.
use rig_core::completion::CompletionRequest;
use rig_core::providers::openai::OpenAI;

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let (base, n, stream) = rust_clients::args();
    // SAFETY: nothing else is running yet.
    unsafe {
        std::env::set_var("OPENAI_API_KEY", rust_clients::key());
        std::env::set_var("OPENAI_BASE_URL", base);
    }
    let model = OpenAI::from_env().expect("a client").chat("mock");
    let model = &model;
    rust_clients::run(n, |i| async move {
        let request = CompletionRequest::new(format!("call {i}"));
        if stream {
            model.stream(request).expect("a stream").finish().await.expect("an answer").text()
        } else {
            model.call(request).await.expect("an answer").text()
        }
    })
    .await;
}
