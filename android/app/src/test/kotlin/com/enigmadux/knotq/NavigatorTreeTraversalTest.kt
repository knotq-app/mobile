package com.enigmadux.knotq

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NavigatorTreeTraversalTest {
    private data class Node(
        val id: String,
        val folder: Boolean,
        val children: List<Node> = emptyList(),
    )

    private fun flatten(roots: List<Node>, collapsed: Set<String> = emptySet()) =
        flattenVisibleTree(
            roots,
            collapsed,
            idOf = Node::id,
            isFolder = Node::folder,
            childrenOf = Node::children,
        )

    @Test
    fun preservesDepthFirstOrderAndPrunesCollapsedSubtrees() {
        val tree = Node(
            "root",
            folder = true,
            children = listOf(
                Node("a", folder = false),
                Node("folder", folder = true, children = listOf(Node("hidden", folder = false))),
                Node("z", folder = false),
            ),
        )

        assertEquals(
            listOf("root" to 0, "a" to 1, "folder" to 1, "hidden" to 2, "z" to 1),
            flatten(listOf(tree)).map { it.first.id to it.second },
        )
        assertEquals(
            listOf("root" to 0, "a" to 1, "folder" to 1, "z" to 1),
            flatten(listOf(tree), setOf("folder")).map { it.first.id to it.second },
        )
    }

    @Test
    fun veryDeepWorkspaceDoesNotUseTheCallStack() {
        var node = Node("leaf", folder = false)
        repeat(50_000) { depth ->
            node = Node("folder-$depth", folder = true, children = listOf(node))
        }

        val visible = flatten(listOf(node))
        assertEquals(50_001, visible.size)
        assertEquals(0, visible.first().second)
        assertEquals(50_000, visible.last().second)
        assertEquals("leaf", visible.last().first.id)
    }

    @Test
    fun deterministicTreeFuzzerKeepsOrderAndNonNegativeDepths() {
        var state = 0x4a11ce55
        fun next(): Int {
            state = state * 1664525 + 1013904223
            return state
        }

        repeat(4096) {
            val leaves = (next().ushr(1) % 12) + 1
            val roots = List(leaves) { index ->
                if ((next() and 3) == 0) {
                    Node("f-$it-$index", folder = true, children = listOf(Node("c-$it-$index", false)))
                } else {
                    Node("s-$it-$index", folder = false)
                }
            }
            val collapsed = roots.filter { it.folder && (next() and 1) == 0 }.map { it.id }.toSet()
            val visible = flatten(roots, collapsed)
            assertTrue(visible.zipWithNext().all { (a, b) -> a.second >= 0 && b.second >= 0 })
            assertTrue(visible.all { it.first.folder || it.first.children.isEmpty() })
            roots.filter { it.id in collapsed }.forEach { folder ->
                assertTrue(visible.any { it.first.id == folder.id })
                assertTrue(folder.children.all { child -> visible.none { it.first.id == child.id } })
            }
        }
    }

    @Test
    fun lazyNavigatorThresholdShortCircuitsLargeTrees() {
        val roots = List(10_000) { index -> Node("scheme-$index", folder = false) }

        assertTrue(
            shouldUseLazyNavigator(
                roots,
                emptySet(),
                idOf = Node::id,
                isFolder = Node::folder,
                childrenOf = Node::children,
                threshold = 200,
            ),
        )
        assertFalse(
            shouldUseLazyNavigator(
                roots,
                emptySet(),
                idOf = Node::id,
                isFolder = Node::folder,
                childrenOf = Node::children,
                threshold = 10_000,
            ),
        )
    }

    @Test
    fun lazyNavigatorDoesNotCountCollapsedDescendants() {
        val folder = Node(
            "folder",
            folder = true,
            children = List(10_000) { index -> Node("hidden-$index", folder = false) },
        )

        assertFalse(
            shouldUseLazyNavigator(
                listOf(folder),
                setOf("folder"),
                idOf = Node::id,
                isFolder = Node::folder,
                childrenOf = Node::children,
                threshold = 200,
            ),
        )
        assertTrue(
            shouldUseLazyNavigator(
                listOf(folder),
                emptySet(),
                idOf = Node::id,
                isFolder = Node::folder,
                childrenOf = Node::children,
                threshold = 200,
            ),
        )
    }
}
