import ast
from pathlib import Path

_SOURCE = Path(__file__).resolve().parents[2] / 'scripts' / 'rag' / 'current.py'


def test_visualization_returns_before_umap_for_empty_or_insufficient_embeddings():
    source_text = _SOURCE.read_text(encoding='utf-8')
    tree = ast.parse(source_text)
    function = next(
        node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'generate_visualization'
    )
    source = ast.get_source_segment(source_text, function)

    assert source is not None
    assert 'if not embedding_values:' in source
    assert 'all_embeddings.shape[0] < 3' in source
    assert 'n_neighbors=min(15, all_embeddings.shape[0] - 1)' in source
    assert source.index('all_embeddings.shape[0] < 3') < source.index('umap.UMAP(')
