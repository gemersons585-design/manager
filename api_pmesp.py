from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import json
import os
import subprocess

app = FastAPI(title="PMESP API")
DB_PATH = "/etc/pmesp_users.json"

class TrocaSenha(BaseModel):
    usuario: str
    senha_atual: str
    nova_senha: str

def carregar_db():
    users = []
    if os.path.exists(DB_PATH):
        with open(DB_PATH, "r") as f:
            for linha in f:
                if linha.strip():
                    users.append(json.loads(linha))
    return users

def salvar_db(users):
    with open(DB_PATH, "w") as f:
        for u in users:
            f.write(json.dumps(u) + "\n")

@app.get("/me/{username}")
async def ver_meus_dados(username: str):
    users = carregar_db()
    u = next((user for user in users if user["usuario"] == username), None)
    if not u: raise HTTPException(status_code=404, detail="Não encontrado")
    return {
        "usuario": u["usuario"],
        "re": u["matricula"],
        "expira_em": u.get("expiracao", "N/A"),
        "limite": u["limite"],
        "hwid": u["hwid"]
    }

@app.post("/alterar-senha")
async def mudar_senha(d: TrocaSenha):
    users = carregar_db()
    for u in users:
        if u["usuario"] == d.usuario:
            if u["senha"] != d.senha_atual:
                raise HTTPException(status_code=403, detail="Senha atual incorreta")
            
            # Altera no Linux
            subprocess.run(f"echo '{d.usuario}:{d.nova_senha}' | chpasswd", shell=True)
            # Altera no JSON
            u["senha"] = d.nova_senha
            salvar_db(users)
            return {"status": "sucesso"}
    raise HTTPException(status_code=404, detail="Usuário não encontrado")
