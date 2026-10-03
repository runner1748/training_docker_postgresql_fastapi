from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import psycopg
import os
#:)
app = FastAPI()
db_host = os.getenv("DB_HOST", "localhost")


def get_conn():
    return psycopg.connect(
        dbname=os.environ["POSTGRES_DB"],
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
        host=db_host,
        port=5432,
    )

@app.get("/health", tags=["health"])
def health():
    try:
        with get_conn() as conn:
            conn.execute("SELECT 1")
    except psycopg.OperationalError:
        raise HTTPException(status_code=503, detail="db unavailable")
    return {"status": "ok"}


class ItemCreate(BaseModel):
    name: str
    status: str

@app.post("/app/task", tags=["add task to db"])
def add_task(item: ItemCreate):
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                CREATE TABLE IF NOT EXISTS tasks (
                id SERIAL PRIMARY KEY,
                task TEXT NOT NULL,
                status TEXT NOT NULL)
                """)

            cur.execute(
                "INSERT INTO tasks (task, status) VALUES (%s, %s) RETURNING id",
                (item.name, item.status),
            )
            new_id = cur.fetchone()[0]

        conn.commit()

    return {"id": new_id, "name": item.name, "status": item.status}


@app.get("/app/task/{task_id}")
def get_task(task_id: int):
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                        "SELECT * FROM tasks WHERE id = %s",
                        (task_id,),
                        )
            data = cur.fetchone()
            if not data:
                raise HTTPException(
                    detail="Task not found",
                    status_code=404
                )
            return data


@app.delete("/app/task/{task_id}")
def delete_task(task_id: int):
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "DELETE FROM tasks WHERE id = %s",
                (task_id,),
            )
            deleted = cur.rowcount
        conn.commit()
    if deleted == 0:
        raise HTTPException(status_code=404, detail="Task not found")
    return {"status": "deleted", "id": task_id}

@app.get("/app/tasks", tags=["show db"])
def show_db():
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT * FROM tasks ORDER BY id"
            )
            data = cur.fetchall()
            if not data:
                raise HTTPException(status_code=404, detail="Task not found")
            return data