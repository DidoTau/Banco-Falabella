#!/usr/bin/python3
from os import listdir
from os.path import splitext, isdir, exists
import textwrap
from gitlab import Gitlab
import sys


class Query:
    """
    Formato query:
    -- Título
    /*
    Descripción
    */
    /*
    Fecha última modificación
    */
    /*
    Modificación hecha
    */
    query
    ;
    """
    def __init__(self, name: str, path: str):
        self.error = None
        self.name = name
        self.path = path

        self.read_file()
        self.process_text()

    def read_file(self):
        with open(f"{self.path}/{self.name}") as f:
            self.lines = f.readlines()

    def process_text(self):
        large = len(self.lines)
        i = 0

        try:
            # Obtener "nombre" query
            while i < large:
                if self.lines[i][0:3] == '-- ':
                    break
                i += 1
            large_name = len(self.lines[i])
            self.name = self.lines[i][3:large_name-1]

            def get_text(i: int):
                while self.lines[i] != '/*\n':
                    i += 1
                i += 1

                init_i = i

                while self.lines[i] != '*/\n':
                    i += 1

                text = self.lines[init_i:i]

                large = len(text) - 1
                for j in range(large):
                    text[j] = text[j].replace('\n', '\\\n')

                def fun_aux(x: tuple):
                    if x[0] == 0:
                        return x[1]
                    else:
                        return "     " + x[1]

                text = list(map(fun_aux, enumerate(text)))
                text = "".join(text)

                return (i, text)

            # Descripción
            (i, self.des) = get_text(i)

            # Fecha última modificación
            (i, self.date) = get_text(i)

            # Modificación
            (i, self.mod) = get_text(i)

            # Query
            i += 1
            self.query = self.lines[i:]

        except IndexError:
            self.error = True

    def create_readme_text_1(self, n: int):
        if self.error is None:
            name = self.name
            name = name.replace('\n', '')

            name_2 = name.lower()
            name_2 = name_2.replace(' ', '-')
        else:
            name = f"Query {self.name} con error"
            name_2 = f"query-{self.name}-con-error"
        text = f" - [{name}](#{name_2})\n\n"

        return text

    def create_readme_text_2(self, n: int, ):
        text = ""

        if self.error is None:
            name = self.name
            text += f"### {name}\n"
            text += f"- #### Descripción\n    - {self.des}\n\n"
            text += f"- #### Fecha última modificación\n    - {self.date}\n\n"
            text += f"- #### Última modificación\n    - {self.mod}\n"

            def fun(x: str):
                return "  " + x

            query_lines = self.query
            query_lines = list(map(fun, query_lines))
            text_query = ""
            text_query = text_query.join(query_lines)
            text += f"#### Query\n```sql\n{text_query}```\n\n"

        else:
            name = f"Query {self.name} con error"
            text += f"### {name}\n"
            text += textwrap.dedent("""
             - Error en el formato del archivo de la query. Recuerda que
             el archivo que contiene la query debe tener el siguiente formato:
             ```sql
               -- Título
               /*
               Descripción
               */
               /*
               Fecha última modificación
               */
               /*
               Modificación hecha
               */
               query
               ;
             ```
              Un ejemplo del formato anterior es el siguiente:
             ```sql
               -- Query de prueba
               /*
               Query de prueba para mostrar el formato
               */
               /*
               16 de Febrero de 1957
               */
               /*
               Se modificó una condición del WHERE
               */
               SELECT
                 IdCliente,
                 IdAgnoMes,
               FROM
                 `alguna_tabla`
               WHERE
                IdAgnoMes = '1972-07-01'
               ;
             ```
             """)
            text += "\n\n"
            n += 1

        return (text, n)


class Dir:
    def __init__(self, name: str,  path: str, gl):
        self.name = name
        self.path = path
        dir_name = name.replace('_', ' ')
        self.dir_name = dir_name
        self.gl = gl

        self.list = []
        self.error_queries = 0

        self.process_dir()
        self.create_readme()

    def process_dir(self):
        for e in listdir(self.path):
            if isdir(f"{self.path}/{e}"):
                self.list.append(Dir(e, f"{self.path}/{e}", self.gl))
            else:
                (name, extension) = splitext(e)
                if extension == '.sql':
                    self.list.append(Query(e, self.path))

    def create_readme_text_1(self, n: int):
        name = self.dir_name
        text = f" - [{name}](./{self.name})\n\n"
        return text

    def create_readme_text_2(self, n: int):
        return("", n)

    def create_readme(self):
        text = f"# {self.dir_name}\n\n## Listado de queries\n"

        for e in self.list:
            text += e.create_readme_text_1(self.error_queries)

        for e in self.list:
            (tmp_text, n) = e.create_readme_text_2(self.error_queries)

            text += tmp_text
            self.error_queries = n

        path = f"{self.path}/README.md"
        action = {
                'action': 'update' if exists(path) else 'create',
                'file_path': path,
                'content': text,
                }

        self.gl.actions.append(action)

        # self.gl.update_readme(f"{self.path}/README.md", text)


class GitLabController:
    def __init__(self, url, token, project, branch):
        self.branch = branch
        self.gl = Gitlab(url=url, private_token=token)
        self.project = self.gl.projects.list(
                visibility='private',
                search=project
                )[0]
        self.actions = []

    def update_readme(self):

        # if exists(path):
        #     action = 'update'
        # else:
        #     action ='create'

        data = {
            'branch': self.branch,
            'commit_message': 'Actualización automática de readme [ci skip]',
            'actions': self.actions
            }
        self.project.commits.create(data)


def main():
    branch = sys.argv[1]
    gl = GitLabController(
            'https://gitlab.falabella.com',
            'wRyMU9GYwnigYQU8iacG',
            'Biblioteca-BI',
            branch
            )

    Dir('QUERIES', "./QUERIES", gl)
    gl.update_readme()


if __name__ == "__main__":
    main()
