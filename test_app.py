from app import app


def test_health():
    assert app.test_client().get('/healthz').json == {'ok': True}
