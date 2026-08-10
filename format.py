import subprocess

def fix_commit():
    with open(".git/COMMIT_EDITMSG", "w") as f:
        f.write("fix: refactor and combine embedding visualization functions\n\nFailure-Class: none\n\nMerges generate_topics_visualization into generate_visualization to unify the RAG topic embedding visualization. Adds fallback support to get_data when memory list is none, resolving issues with empty topic list evaluation in umap slicing. Removes the old generate_topics_visualization and updates the run script entry point. Also applies black formatting to satisfy CI checks.")

fix_commit()
