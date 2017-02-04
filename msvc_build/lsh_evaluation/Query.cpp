#include "Query.h"
#include "KDTree.h"

namespace popsift {
namespace kdtree {

TreeQuery::TreeQuery(const U8Descriptor * qDescriptors, size_t dcount, 
                    unsigned treeIndex, Query* query)
    :_qDescriptors(qDescriptors),
    _dcount(dcount),
    _initialTreeIndex(treeIndex),
    _query(query)
{
}

void TreeQuery::FindCandidates()
{
    for (int i = 0; i < _dcount; i++) {
        const U8Descriptor& desc = _qDescriptors[i];

        //initial traverse from root-node
        traverse(desc, 0, _initialTreeIndex);

        //followup-traversal based on priority queue
        while (_candidates.size() < _maxCandidates && _query->priority_queue.size() > 0) {
            
            int nextIndex = -1;
            unsigned nextTreeIndex;
            {
                std::lock_guard<std::mutex>(_query->pq_mutex);
                if (_query->priority_queue.size() > 0) {
                    nextIndex = _query->priority_queue.top().nodeIndex;
                    nextTreeIndex = _query->priority_queue.top().treeIndex;
                    _query->priority_queue.pop();
                }
            }
            if (nextIndex >= 0)
                traverse(desc, nextIndex, nextTreeIndex);
        }

        //Moved the priority-queue traversal from leaf-node block 
        //in TreeQuery::traverse to avoid huge stacks
    }
}

void TreeQuery::traverse(const U8Descriptor & q, unsigned nodeIndex, unsigned treeIndex)
{
    const KDTree& tree = _query->Tree(treeIndex);

    if (tree.IsLeaf(nodeIndex)) {
        auto candidates = _tree->List(nodeIndex);
        _candidates.insert(_candidates.end(), candidates.first, candidates.second);
        //todo: can potentially calc dist between q and tree-desc here.
    }
    else {
        if (tree.Val(nodeIndex) < q.ufeatures[tree.Dim(nodeIndex)]) {
            const BoundingBox& rightBB = _tree->BB(_tree->Right(nodeIndex));
            unsigned right_dist = BBDistance(rightBB, q);
            {
                std::lock_guard<std::mutex>(_query->pq_mutex);
                _query->priority_queue.push(Query::PC{ treeIndex, _tree->Right(nodeIndex), right_dist });
            }
            traverse(q, _tree->Left(nodeIndex), treeIndex);
        }
        else {
            const BoundingBox& leftBB = _tree->BB(_tree->Left(nodeIndex));
            unsigned left_dist = BBDistance(leftBB, q);
            
            {
                std::lock_guard<std::mutex>(_query->pq_mutex);
                _query->priority_queue.push(Query::PC{ treeIndex, _tree->Right(nodeIndex), left_dist });
            }
            traverse(q, _tree->Right(nodeIndex), treeIndex);
        }
    }
}

unsigned TreeQuery::BBDistance(const BoundingBox& bb, const U8Descriptor & q)
{
    unsigned sum = 0;
    for (int i = 0; i < 128; i++) {
        if (q.ufeatures[i] < bb.min.ufeatures[i]) {
            sum += bb.min.ufeatures[i] - q.ufeatures[i];
        }
        else if (q.ufeatures[i] > bb.max.ufeatures[i]) {
            sum += q.ufeatures[i] - bb.max.ufeatures[i];
        }
    }
    return sum;
}

Query::Query(const U8Descriptor * qDescriptors, size_t dcount,
    std::vector<std::unique_ptr<KDTree>> trees, unsigned num_threads)
{
    for (int i = 0; i < trees.size(); i++) {
        TreeQuery q(qDescriptors, dcount, i, this);

    }
}


}
}