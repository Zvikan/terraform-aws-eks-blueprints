import os
import re

# Env Vars pulled from local or GitHub Action
TAG_VERSION = os.getenv("TAG_VERSION", default="v4.4.0")
CONVERT_TO_GITHUB = os.getenv("CONVERT_TO_GITHUB", default=False)
UPDATE_TAG = os.getenv("UPDATE_TAG", default=False)

GITHUB_URL = "github.com/aws-ia/terraform-aws-eks-blueprints"
PROJECT_NAME = "terraform-aws-eks-blueprints"


def main():
    files_to_handle = []
    get_examples_paths(files_to_handle)

    for path in files_to_handle:
        source_map = {}
        map_modules_sources(path, source_map)
        if UPDATE_TAG:
            set_new_gh_version(source_map)
        else:
            set_new_github_source(source_map, path)
        data = replace_sources(path, source_map)
        write_file_changes(data, path)


def write_file_changes(data, path):
    with open(path, 'w') as file:
        file.write(data)


def replace_sources(path, source_map):
    with open(path, 'r') as file:
        data = file.read()
        for source in source_map:
            data = data.replace(source, source_map[source])
    return data


def get_root_folder_path():
    return os.path.abspath(os.path.join(os.curdir, ".."))


def get_trimmed_relative_path(source, relative_path):
    # Trim everything after '?' for GitHub reference
    result = re.sub("\\?.*", '', source)
    # Replace GH link with relative path
    result = result.replace(GITHUB_URL, relative_path)
    # Replace double slash with single slash
    result = result.replace("//", "/")
    result = result.replace("\"", "")
    return result


def set_new_gh_version(source_map):
    for source in source_map:
        source_map[source] = re.sub("\\?.*", '', source) + "?ref={}\"".format(TAG_VERSION)


def set_new_github_source(source_map, example_path):
    for source in source_map:
        if CONVERT_TO_GITHUB:
            if "/modules/" in source:
                source_map[source] = "\"{}//{}?ref={}\"".format(GITHUB_URL, source.replace("../", "").replace("\"", ""),
                                                                TAG_VERSION)
            else:
                source_map[source] = "\"{}?ref={}\"".format(GITHUB_URL, TAG_VERSION)
        else:
            root_folder_path = get_root_folder_path()
            relative_path = os.path.relpath(root_folder_path, os.path.dirname(example_path))
            if "/modules/" in source:
                trimmed_path = get_trimmed_relative_path(source, relative_path)
                source_map[source] = "\"{}\"".format(trimmed_path)
            else:
                source_map[source] = "\"{}\"".format(relative_path)


def map_modules_sources(path, source_map):
    with open(path, 'r') as file:
        for line in file.readlines():
            if line.strip().startswith("source"):
                source_path = line.strip().replace(" ", "").partition("=")[2]
                if CONVERT_TO_GITHUB:
                    if source_path.startswith("\"../"):
                        source_map[source_path] = ""
                # Map GH sources if convert from GH to local OR if need to update tags
                elif not CONVERT_TO_GITHUB or UPDATE_TAG:
                    if source_path.startswith("\"{}".format(GITHUB_URL)):
                        source_map[source_path] = ""


def get_examples_folder_path():
    return os.path.join(get_root_folder_path(), "examples")


def get_examples_paths(files_to_handle):
    exclude = [".terraform"]
    examples_folder_path = get_examples_folder_path()
    for root, dirs, files in os.walk(examples_folder_path, topdown=True):
        [dirs.remove(d) for d in list(dirs) if d in exclude]
        for x in files:
            if x.strip().lower() == "main.tf":
                files_to_handle.append(os.path.join(root, x))


main()
