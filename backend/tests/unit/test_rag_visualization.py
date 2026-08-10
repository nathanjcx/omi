from types import ModuleType, SimpleNamespace
from unittest.mock import MagicMock

import numpy as np

from testing.import_isolation import AutoMockModule, load_module_fresh, stub_modules


def _load_visualization_module():
    shared = AutoMockModule('_shared')
    chat = AutoMockModule('models.chat')
    conversation = AutoMockModule('models.conversation')
    umap_module = ModuleType('umap')
    plotly_module = ModuleType('plotly')
    plotly_subplots = ModuleType('plotly.subplots')
    plotly_subplots.make_subplots = MagicMock()
    plotly_module.subplots = plotly_subplots
    umap_module.UMAP = MagicMock()
    with stub_modules(
        {
            '_shared': shared,
            'models.chat': chat,
            'models.conversation': conversation,
            'umap': umap_module,
            'plotly': plotly_module,
            'plotly.subplots': plotly_subplots,
        }
    ):
        return load_module_fresh('rag_current_visualization', 'scripts/rag/current.py'), umap_module


def test_generate_visualization_keeps_topic_augmented_small_memory_set(monkeypatch, tmp_path):
    module, umap_module = _load_visualization_module()
    monkeypatch.chdir(tmp_path)
    module.get_data = lambda topics: {
        'memory-1': ['First', [1.0, 0.0], ['topic']],
        'memory-2': ['Second', [0.0, 1.0], []],
    }
    module.openai_embeddings = SimpleNamespace(embed_query=lambda topic: [0.5, 0.5])
    module.get_markers = MagicMock(return_value=object())
    module.get_query_marker = MagicMock(return_value=object())
    module.generate_html_visualization = MagicMock()
    module.go = SimpleNamespace(Scatter=MagicMock())
    figure = MagicMock()
    module.make_subplots = MagicMock(return_value=figure)
    umap_instance = MagicMock()
    umap_instance.fit_transform.return_value = np.array([[0.0, 0.0], [1.0, 1.0], [2.0, 2.0]])
    umap_module.UMAP.return_value = umap_instance

    module.generate_visualization(['topic'])

    assert umap_instance.fit_transform.call_args.args[0].shape == (3, 2)
    assert module.generate_html_visualization.called


def test_generate_visualization_keeps_all_memory_points_without_topics(monkeypatch, tmp_path):
    module, umap_module = _load_visualization_module()
    monkeypatch.chdir(tmp_path)
    module.get_data = lambda topics: {
        'memory-1': ['First', [1.0, 0.0], []],
        'memory-2': ['Second', [0.0, 1.0], []],
        'memory-3': ['Third', [1.0, 1.0], []],
    }
    module.get_markers = MagicMock(return_value=object())
    module.generate_html_visualization = MagicMock()
    figure = MagicMock()
    module.make_subplots = MagicMock(return_value=figure)
    umap_instance = MagicMock()
    umap_instance.fit_transform.return_value = np.array([[0.0, 0.0], [1.0, 1.0], [2.0, 2.0]])
    umap_module.UMAP.return_value = umap_instance

    module.generate_visualization([])

    assert umap_instance.fit_transform.call_args.args[0].shape == (3, 2)
    assert module.generate_html_visualization.called
