# Título nível 1

Parágrafo comum. Nada deve mudar aqui.

## Título nível 2

### Título nível 3

#### Título nível 4

##### Título nível 5

###### Título nível 6

#Sem espaço depois do hash: não é título, não deve mudar.

  ## Título com 2 espaços de recuo (ainda é título em Markdown)

> # Título dentro de citação (o regex não pegava este)

## Passo 2: blocos de código não viram título

O comentário dentro do bloco abaixo NÃO deve virar título:

```bash
# isto é um comentário de bash
echo "olá"
```

Nem dentro de um bloco de Markdown:

```markdown
# isto é um exemplo de markdown, não um título de verdade
```

    # bloco indentado com 4 espaços também é código

## Bug conhecido (passo 3 resolve)

Ponha o cursor numa linha de título: o `##` volta a aparecer, mas o `◆`
continua lá.
