from sqlalchemy import create_engine
from sqlalchemy.exc import SQLAlchemyError
from utils.connection import(
    POSTGRES_HOST,
    POSTGRES_PORT,
    POSTGRES_DATABASE,
    POSTGRES_USERNAME,
    POSTGRES_PASSWORD
)

from utils.logger import get_logger

logger = get_logger("bronze", "engines")


# =========================================================
# POSTGRES
# =========================================================

def postgres_engine():
    try:
        connection_url = (
            f"postgresql+psycopg2://"
            f"{POSTGRES_USERNAME}:"
            f"{POSTGRES_PASSWORD}@"
            f"{POSTGRES_HOST}:"
            f"{POSTGRES_PORT}/"
            f"{POSTGRES_DATABASE}"
        )

        engine = create_engine(
            connection_url,
            pool_pre_ping=True,
            pool_size=5,
            max_overflow=10,
        )

        logger.info(f"Postgres engine created → {POSTGRES_HOST}/{POSTGRES_DATABASE}")
        return engine

    except SQLAlchemyError as e:
        logger.error(f"Postgres engine failed: {e}")
        raise
