use axum::{
    extract::{Path, State},
    http::{HeaderValue, StatusCode},
    routing::get,
    Router,
};
use rusqlite::{Connection, Result as SqliteResult};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::Mutex;
use tower_http::cors::{Any, CorsLayer};

#[derive(Serialize, Deserialize)]
struct ViewCount {
    views: i64,
}

pub struct AppState {
    db: Mutex<Connection>,
}

const PORT: &str = "3002";

// TODO: fix cors
fn build_cors(_origins: Vec<HeaderValue>) -> CorsLayer {
    CorsLayer::new()
        .allow_origin(Any)
        .allow_methods([axum::http::Method::GET])
        .allow_credentials(true)
}

#[tokio::main]
async fn main() {
    let conn = Connection::open("viewcount.db").expect("Failed to open database");
    conn.execute(
        "CREATE TABLE IF NOT EXISTS pageviews (
            page_path TEXT PRIMARY KEY,
            views INTEGER DEFAULT 0,
            last_viewed TIMESTAMP
        )",
        [],
    )
    .expect("Failed to create table");

    println!("Using Cors!");

    let state = Arc::new(AppState {
        db: Mutex::new(conn),
    });

    let origins = [
        "http://127.0.0.1:1111".parse().unwrap(),
        "https://pert.dev".parse().unwrap(),
        "https://backend.pert.dev".parse().unwrap(),
    ];
    let cors = build_cors(origins.to_vec());

    let app = Router::new()
        .route("/count/*path", get(count_view))
        .layer(cors)
        .with_state(state);

    let addr = format!("0.0.0.0:{PORT}");
    println!("Listening on {}", &addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

async fn count_view(
    Path(path): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<axum::Json<ViewCount>, StatusCode> {
    let conn = state.db.lock().await;

    let result: SqliteResult<i64> = conn.query_row(
        "INSERT INTO pageviews (page_path, views, last_viewed)
         VALUES (?1, 1, CURRENT_TIMESTAMP)
         ON CONFLICT(page_path) DO UPDATE SET
            views = views + 1,
            last_viewed = CURRENT_TIMESTAMP
         RETURNING views",
        [&path],
        |row| row.get(0),
    );

    match result {
        Ok(count) => Ok(axum::Json(ViewCount { views: count })),
        Err(_) => Err(StatusCode::INTERNAL_SERVER_ERROR),
    }
}

#[cfg(test)]
mod tests {
    use std::usize;

    use super::*;
    use axum::body::to_bytes;
    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use tempfile::NamedTempFile;
    use tower::util::ServiceExt;
    use tower_http::cors::Any;

    async fn setup_test_app() -> (Router, NamedTempFile) {
        let db_file = NamedTempFile::new().expect("Failed to create temp file");
        let conn = Connection::open(db_file.path()).expect("Failed to open database");

        // Initialize schema
        conn.execute(
            "CREATE TABLE IF NOT EXISTS pageviews (
                page_path TEXT PRIMARY KEY,
                views INTEGER DEFAULT 0,
                last_viewed TIMESTAMP
            )",
            [],
        )
        .expect("Failed to create table");

        // Create app state with test database
        let state = Arc::new(AppState {
            db: Mutex::new(conn),
        });

        let cors = CorsLayer::new()
            .allow_origin(Any)
            .allow_methods([axum::http::Method::GET])
            .allow_credentials(true);

        let app = Router::new()
            .route("/count/*path", get(count_view))
            .layer(cors)
            .with_state(state);

        (app, db_file)
    }

    #[tokio::test]
    async fn test_initial_page_view() {
        let (app, _temp_db) = setup_test_app().await;

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/count/test-page")
                    .method("GET")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);

        let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        let view_count: ViewCount = serde_json::from_slice(&body).unwrap();

        assert_eq!(view_count.views, 1);
    }

    #[tokio::test]
    async fn test_multiple_page_views() {
        let (app, _temp_db) = setup_test_app().await;
        let test_uri = "/count/multiple-test";

        // Make three requests
        for expected_count in 1..=3 {
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .uri(test_uri)
                        .method("GET")
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();

            assert_eq!(response.status(), StatusCode::OK);

            let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
            let view_count: ViewCount = serde_json::from_slice(&body).unwrap();

            assert_eq!(view_count.views, expected_count);
        }
    }

    #[tokio::test]
    async fn test_multiple_pages() {
        let (app, _temp_db) = setup_test_app().await;

        // Test different pages get different counters
        let pages = vec!["/count/page1", "/count/page2", "/count/page3"];

        for page in pages {
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .uri(page)
                        .method("GET")
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();

            assert_eq!(response.status(), StatusCode::OK);

            let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
            let view_count: ViewCount = serde_json::from_slice(&body).unwrap();

            assert_eq!(view_count.views, 1);
        }
    }

    #[tokio::test]
    async fn test_special_characters_in_path() {
        let (app, _temp_db) = setup_test_app().await;

        let test_uri = "/count/special%20path%21%40%23"; // "special path!@#"

        let response = app
            .oneshot(
                Request::builder()
                    .uri(test_uri)
                    .method("GET")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);

        let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        let view_count: ViewCount = serde_json::from_slice(&body).unwrap();

        assert_eq!(view_count.views, 1);
    }

    #[tokio::test]
    async fn test_concurrent_requests() {
        let (app, _temp_db) = setup_test_app().await;
        let test_uri = "/count/concurrent-test";

        // Create 10 concurrent requests
        let futures: Vec<_> = (0..10)
            .map(|_| {
                app.clone().oneshot(
                    Request::builder()
                        .uri(test_uri)
                        .method("GET")
                        .body(Body::empty())
                        .unwrap(),
                )
            })
            .collect();

        let responses = futures::future::join_all(futures).await;

        for response in &responses {
            assert!(response.is_ok());
            assert_eq!(response.as_ref().unwrap().status(), StatusCode::OK);
        }

        let final_response = app
            .oneshot(
                Request::builder()
                    .uri(test_uri)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        let body = to_bytes(final_response.into_body(), usize::MAX)
            .await
            .unwrap();
        let view_count: ViewCount = serde_json::from_slice(&body).unwrap();

        // Should be exactly 11 views (10 concurrent + 1 final check)
        assert_eq!(view_count.views, 11);
    }
}
