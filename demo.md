# Demo do nanquim

Parágrafo comum: nada muda aqui.

## Títulos

### Nível 3

#### Nível 4

##### Nível 5

###### Nível 6

#sem espaço não é título

> # Título dentro de citação

## Texto inline

Texto com **negrito**, *itálico*, ***os dois***, `código` e ~~tachado~~.

Um [link para o Neovim](https://neovim.io "site oficial") e um link direto:
<https://github.com>.

Imagem com texto alternativo: ![logo do nanquim](imagens/logo.png)

Imagem sem texto alternativo: ![](imagens/paisagem.png)

### Título com `código` e **negrito**

## Tabelas

Alinhada: ganha bordas, e as células com negrito, código e link continuam
alinhadas mesmo com a marcação escondida.

| Elemento | Exemplo                     | Status |
|----------|-----------------------------|--------|
| Negrito  | **forte**                   | ok     |
| Código   | `vim.api`                   | ok     |
| Link     | [Neovim](https://neovim.io) | ok     |
| Acentos  | ação, coração               | ok     |

Desalinhada: só troca os `|` e a linha do meio, sem bordas.

| a | b |
|---|---|
| célula longa | x |

Sem `|` nas pontas:

x | y
--|--
1 | 2

## Blocos de código

```lua
local function oi(nome)
  return "olá, " .. nome
end
```

~~~
bloco sem linguagem
~~~

```bash
# comentário de bash, não é título
```

```markdown
# exemplo de markdown, não é título
```

## Listas

- nível 1
  - nível 2
    - nível 3
      - nível 4
        - nível 5 volta ao símbolo do nível 1
* asterisco também vira bullet
+ mais também

1. lista numerada
2. fica com os números

- [ ] tarefa pendente
- [x] tarefa feita
  - [X] subtarefa feita, com X maiúsculo
1. [ ] tarefa numerada mantém o número

## Citações e callouts

> Citação comum: o `>` vira uma barra.
> Segunda linha da mesma citação.
>
> > Citação aninhada: duas barras.

> [!NOTE]
> Informação que vale notar.

> [!TIP]
> Uma dica para fazer melhor.

> [!IMPORTANT]
> Algo essencial para o objetivo.

> [!WARNING]
> Pede atenção para evitar problemas.

> [!CAUTION]
> Risco de consequência negativa.

> [!NOTA]
> Tipo desconhecido fica como citação comum.

## Linha horizontal

---

***

Título sublinhado (o --- abaixo não é linha horizontal)
---
